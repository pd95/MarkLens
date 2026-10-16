#!/usr/bin/env python3
"""Retrieve only the completed, stapled artifact from an Xcode Cloud release.

Apple authentication is used for artifact retrieval, never a second notarization.
Requires Python's standard library and OpenSSL (available on the CI runner).
"""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from release_updates import ReleaseError, TAG_PATTERN

API = "https://api.appstoreconnect.apple.com/v1/"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_es256_signature(der):
    # OpenSSL produces two DER integers; JWT requires their 32-byte concatenation.
    if len(der) < 6 or der[0] != 0x30 or der[1] != len(der) - 2:
        raise ReleaseError("OpenSSL returned an invalid ES256 signature")
    offset = 2
    parts = []
    for _ in range(2):
        if offset + 2 > len(der) or der[offset] != 2:
            raise ReleaseError("OpenSSL returned an invalid ES256 integer")
        length = der[offset + 1]
        part = der[offset + 2:offset + 2 + length].lstrip(b"\0")
        if not length or len(part) > 32 or offset + 2 + length > len(der):
            raise ReleaseError("OpenSSL returned an invalid ES256 integer length")
        parts.append(part.rjust(32, b"\0"))
        offset += 2 + length
    if offset != len(der):
        raise ReleaseError("OpenSSL returned trailing ES256 signature data")
    return b"".join(parts)


class APIOnlyRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        if not new_url.startswith(API):
            raise ReleaseError("Refusing an Apple API redirect outside the API")
        return super().redirect_request(request, response, code, message, headers, new_url)


class AppleCloud:
    def __init__(self, environment):
        self.key = environment.get("APP_STORE_CONNECT_API_PRIVATE_KEY", "")
        self.key_id = environment.get("APP_STORE_CONNECT_API_KEY_ID", "")
        self.issuer = environment.get("APP_STORE_CONNECT_API_ISSUER_ID", "")
        if not all((self.key, self.key_id, self.issuer)):
            raise ReleaseError("Configure the three APP_STORE_CONNECT_API_* GitHub secrets with a team API key")
        self.token = None
        self.expires = 0

    def bearer_token(self):
        if self.token and time.time() < self.expires - 30:
            return self.token
        now = int(time.time())
        header = b64url(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
        claims = b64url(json.dumps({"iss": self.issuer, "iat": now, "exp": now + 600,
                                   "aud": "appstoreconnect-v1"}).encode())
        unsigned = f"{header}.{claims}"
        with tempfile.TemporaryDirectory(prefix="marklens-apple-auth-") as temporary:
            key_path = Path(temporary) / "AuthKey.p8"
            descriptor = os.open(key_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(descriptor, "w") as file:
                file.write(self.key.strip() + "\n")
            signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)],
                                       input=unsigned.encode(), capture_output=True)
            if signature.returncode:
                raise ReleaseError("Cannot sign Apple API token; check the team API private key")
        self.token = unsigned + "." + b64url(raw_es256_signature(signature.stdout))
        self.expires = now + 600
        return self.token

    def get(self, path):
        url = urllib.parse.urljoin(API, path)
        if not url.startswith(API):
            raise ReleaseError("Refusing to send Apple credentials outside the API")
        request = urllib.request.Request(url, headers={"Authorization": "Bearer " + self.bearer_token(),
                                                       "Accept": "application/json"})
        try:
            with urllib.request.build_opener(APIOnlyRedirects()).open(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise ReleaseError(f"Apple API request failed (HTTP {error.code})") from None

    def list(self, path):
        result = []
        for _ in range(100):
            page = self.get(path)
            result.extend(page["data"])
            path = page.get("links", {}).get("next")
            if not path:
                return result
        raise ReleaseError("Apple API pagination limit exceeded")


def publication_request(environment):
    values = {key: environment.get(key, "") for key in
              ("CLOUD_BUILD_ID", "RELEASE_TAG", "RELEASE_COMMIT", "CLOUD_BUILD_NUMBER")}
    if not re.fullmatch(r"[A-Za-z0-9-]+", values["CLOUD_BUILD_ID"]):
        raise ReleaseError("Missing or invalid Xcode Cloud build ID")
    if not TAG_PATTERN.fullmatch(values["RELEASE_TAG"]) or "-test" in values["RELEASE_TAG"]:
        raise ReleaseError("Invalid release tag")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", values["RELEASE_COMMIT"]):
        raise ReleaseError("Missing full release commit SHA")
    if not values["CLOUD_BUILD_NUMBER"].isdecimal():
        raise ReleaseError("Missing Xcode Cloud build number")
    return values


def wait_for_artifact(client, request, *, attempts=90, delay=30):
    run_id = request["CLOUD_BUILD_ID"]
    for _ in range(attempts):
        build = client.get(f"ciBuildRuns/{run_id}")["data"]["attributes"]
        if build.get("isPullRequestBuild") or str(build.get("number")) != request["CLOUD_BUILD_NUMBER"]:
            raise ReleaseError("Apple build does not match the requested release")
        source = (build.get("sourceCommit") or {}).get("commitSha")
        if source and source != request["RELEASE_COMMIT"]:
            raise ReleaseError("Apple build commit does not match the requested release")
        reference = client.get(f"ciBuildRuns/{run_id}/sourceBranchOrTag")["data"]["attributes"]
        if reference.get("kind") != "TAG" or reference.get("canonicalName") != "refs/tags/" + request["RELEASE_TAG"]:
            raise ReleaseError("Apple build is not for the requested release tag")
        if build.get("executionProgress") != "COMPLETE":
            time.sleep(delay)
            continue
        if build.get("completionStatus") != "SUCCEEDED":
            raise ReleaseError("Xcode Cloud did not finish successfully; nothing will be published")
        artifacts = []
        for action in client.list(f"ciBuildRuns/{run_id}/actions?limit=200"):
            attributes = action["attributes"]
            if attributes.get("actionType") == "ARCHIVE" and attributes.get("completionStatus") == "SUCCEEDED":
                artifacts.extend(client.list(f"ciBuildActions/{action['id']}/artifacts?limit=200"))
        stapled = [item for item in artifacts
                   if item["attributes"].get("fileType") == "STAPLED_NOTARIZED_ARCHIVE"]
        if len(stapled) > 1:
            raise ReleaseError("Multiple notarized archives found; use a dedicated macOS release workflow")
        if stapled:
            artifact = client.get(f"ciArtifacts/{stapled[0]['id']}")["data"]
            return artifact["attributes"]["downloadUrl"]
        # Completed build metadata/artifact indexing can become visible separately.
        time.sleep(delay)
    raise ReleaseError("Timed out waiting for Cloud's completed stapled notarized artifact")


def download_artifact(url, destination):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ReleaseError("Apple returned an invalid artifact download URL")
    # The pre-signed download URL must never receive the Apple bearer token.
    try:
        with urllib.request.urlopen(url, timeout=120) as response, open(destination, "wb") as file:
            shutil.copyfileobj(response, file)
    except urllib.error.HTTPError as error:
        raise ReleaseError(f"Apple artifact download failed (HTTP {error.code})") from None


if __name__ == "__main__":
    try:
        request = publication_request(os.environ)
        destination = Path(sys.argv[1])
        url = wait_for_artifact(AppleCloud(os.environ), request)
        download_artifact(url, destination)
        print("Downloaded the completed, stapled Xcode Cloud artifact.")
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
