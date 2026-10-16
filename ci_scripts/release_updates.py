#!/usr/bin/env python3
"""Publish immutable ZIPs and a Sparkle appcast in Xcode Cloud after scripted notarization.

No third-party Python dependencies. Authentication and signing keys never appear
in command arguments or git remote URLs. Git's ref update provides the compare-
and-swap boundary for concurrent feed publications.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
FEED_PATH = "updates/appcast.xml"
FEED_URL = "https://pd95.github.io/MarkLens/updates/appcast.xml"
TAG_PATTERN = re.compile(r"v?(\d+(?:\.\d+){1,2})(-[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*)?$")
HEADING = re.compile(r"^##\s+\[?(\d+(?:\.\d+){1,2})\]?(?:\s+\(Unreleased\))?\s*$", re.I)


class ReleaseError(Exception):
    pass


class APIError(ReleaseError):
    def __init__(self, status, operation):
        self.status = status
        super().__init__(f"GitHub {operation} failed with HTTP {status}")


def run(arguments, *, secret=None):
    result = subprocess.run([str(a) for a in arguments], input=secret, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Do not echo tool output: malformed secrets can be repeated by tools.
        raise ReleaseError(f"{Path(arguments[0]).name} failed (exit {result.returncode})")
    return result.stdout


def changelog_notes(markdown, target):
    """Publish canonical version headings for the native attributed-note filter."""
    sections = []
    current = None
    body = []
    for line in markdown.splitlines() + ["## End"]:
        if line.startswith("## "):
            if current is not None:
                sections.append((current, "\n".join(body).strip()))
            match = HEADING.fullmatch(line)
            current = match.group(1) if match else None
            body = []
        elif current is not None:
            body.append(line)
    version = lambda value: tuple((list(map(int, value.split("."))) + [0, 0])[:3])
    if not any(v == target for v, _ in sections):
        raise ReleaseError(f"CHANGELOG.md has no section for {target}")
    return "\n\n".join(f"## Version {v}\n\n{text}" for v, text in sections
                        if version(v) <= version(target)) + "\n"


def validate_feed(data, build, tag, archive, url, preview):
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise ReleaseError("Generated appcast is not valid XML") from error
    found = [item for item in root.findall("./channel/item")
             if item.findtext(f"{{{SPARKLE}}}version") == build]
    if len(found) != 1:
        raise ReleaseError("Appcast must contain exactly one item for this build")
    item = found[0]
    enclosure = item.find("enclosure")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature", "") if enclosure is not None else ""
    try:
        valid_signature = len(base64.b64decode(signature, validate=True)) == 64
    except ValueError:
        valid_signature = False
    if not valid_signature:
        raise ReleaseError("Update has no valid Ed25519 signature; check the signing key")
    if enclosure.get("url") != url or enclosure.get("length") != str(archive.stat().st_size):
        raise ReleaseError("Appcast does not describe the uploaded archive")
    channel = item.findtext(f"{{{SPARKLE}}}channel")
    if channel != ("preview" if preview else None):
        raise ReleaseError("Appcast has the wrong release channel")
    return root, item


class GitHub:
    def __init__(self, repository, token, api="https://api.github.com", uploads="https://uploads.github.com"):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ReleaseError("Invalid GITHUB_REPOSITORY")
        self.repository = repository
        self.token = token
        self.api = api.rstrip("/")
        self.uploads = uploads.rstrip("/")

    def request(self, method, path, payload=None, *, binary=None, uploads=False):
        base = self.uploads if uploads else self.api
        data = binary if binary is not None else (json.dumps(payload).encode() if payload is not None else None)
        request = urllib.request.Request(f"{base}/repos/{self.repository}/{path}", data=data, method=method,
            headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "MarkLens-release",
                     "Content-Type": "application/zip" if binary is not None else "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            raise APIError(error.code, f"{method} {path.split('?')[0]}") from None

    def feed_snapshot(self):
        try:
            ref = self.request("GET", "git/ref/heads/gh-pages")
        except APIError as error:
            if error.status == 404:
                return None, None, None
            raise
        head = ref["object"]["sha"]
        tree = self.request("GET", f"git/commits/{head}")["tree"]["sha"]
        try:
            file = self.request("GET", f"contents/{FEED_PATH}?ref={head}")
            feed = base64.b64decode(file["content"])
        except APIError as error:
            if error.status != 404:
                raise
            feed = None
        return head, tree, feed

    def publish_files(self, head, tree, files):
        entries = []
        for path, content in files.items():
            blob = self.request("POST", "git/blobs", {"encoding": "base64", "content": base64.b64encode(content).decode()})
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        payload = {"tree": entries}
        if tree:
            payload["base_tree"] = tree
        new_tree = self.request("POST", "git/trees", payload)["sha"]
        commit = self.request("POST", "git/commits", {"message": "Publish signed MarkLens update feed", "tree": new_tree,
                                                       "parents": [head] if head else []})["sha"]
        if head:
            self.request("PATCH", "git/refs/heads/gh-pages", {"sha": commit, "force": False})
        else:
            self.request("POST", "git/refs", {"ref": "refs/heads/gh-pages", "sha": commit})

    def release(self, tag, preview, body):
        path = "releases/tags/" + urllib.parse.quote(tag, safe="")
        try:
            return self.request("GET", path)
        except APIError as error:
            if error.status != 404:
                raise
        try:
            return self.request("POST", "releases", {"tag_name": tag, "name": f"MarkLens {tag}", "body": body,
                "draft": False, "prerelease": preview, "make_latest": "false" if preview else "true"})
        except APIError as error:
            if error.status != 422:
                raise
            return self.request("GET", path)

    def assets(self, release_id):
        result = []
        for page in range(1, 101):
            batch = self.request("GET", f"releases/{release_id}/assets?per_page=100&page={page}")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise ReleaseError("Too many release assets")

    def upload_archive(self, release, archive, tag):
        """An existing archive is immutable, including on reruns and race recovery."""
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        for attempt in range(3):
            existing = next((a for a in self.assets(release["id"]) if a["name"] == archive.name), None)
            if existing:
                expected = f"https://github.com/{self.repository}/releases/download/{tag}/{archive.name}"
                if existing.get("state") != "uploaded" or existing.get("browser_download_url") != expected:
                    raise ReleaseError("Existing release archive is incomplete or has an unexpected URL")
                # Download without credentials; never trust a GitHub asset URL to receive the token.
                with urllib.request.urlopen(expected, timeout=120) as response:
                    remote = response.read()
                if hashlib.sha256(remote).hexdigest() != digest:
                    raise ReleaseError("This tag already has different ZIP bytes; publish a new tag instead")
                return expected
            try:
                asset = self.request("POST", f"releases/{release['id']}/assets?name={urllib.parse.quote(archive.name)}",
                                     binary=archive.read_bytes(), uploads=True)
                expected = f"https://github.com/{self.repository}/releases/download/{tag}/{archive.name}"
                if asset.get("state") != "uploaded" or asset.get("browser_download_url") != expected:
                    raise ReleaseError("GitHub did not confirm the uploaded archive")
                # Verify the bytes GitHub stored, rather than only its upload response.
                with urllib.request.urlopen(expected, timeout=120) as response:
                    remote = response.read()
                if hashlib.sha256(remote).hexdigest() != digest:
                    raise ReleaseError("Uploaded archive checksum does not match")
                return expected
            except APIError as error:
                if error.status != 422 or attempt == 2:
                    raise
        raise ReleaseError("Could not publish archive")


def release_version_key(value):
    match = TAG_PATTERN.fullmatch(value)
    if not match:
        raise ReleaseError("Feed contains an unsupported release version")
    base, suffix = match.groups()
    components = tuple((list(map(int, base.split("."))) + [0, 0])[:3])
    if suffix is None:
        return components, (1, ())
    identifiers = []
    for part in suffix[1:].split("."):
        if part.isdecimal():
            identifiers.append((0, int(part)))
        else:
            trailing = re.fullmatch(r"(.*?)([0-9]+)", part)
            identifiers.append((1, trailing[1] if trailing else part,
                                int(trailing[2]) if trailing else -1))
    return components, (0, tuple(identifiers))


def ensure_increasing(feed, build, tag, url):
    if feed is None:
        return
    try:
        items = ET.fromstring(feed).findall("./channel/item")
    except ET.ParseError as error:
        raise ReleaseError("Existing feed is invalid; refusing to overwrite it") from error
    # A retry of an already advertised artifact is allowed even after newer releases.
    for item in items:
        enclosure = item.find("enclosure")
        if enclosure is not None and enclosure.get("url") == url:
            if (item.findtext(f"{{{SPARKLE}}}version") != build
                    or item.findtext(f"{{{SPARKLE}}}shortVersionString") != tag.removeprefix("v")):
                raise ReleaseError("This tag is already published with different version metadata")
            return
    current = release_version_key(tag)
    for item in items:
        version = item.findtext(f"{{{SPARKLE}}}version", "")
        if not version.isdecimal():
            raise ReleaseError("Existing feed contains a nonnumeric build number")
        if int(version) >= int(build):
            raise ReleaseError("Build number must increase across Stable and Preview releases")
        if current <= release_version_key(item.findtext(f"{{{SPARKLE}}}shortVersionString", "")):
            raise ReleaseError("Release version must advance the single Stable/Preview release train")


def find_sparkle_tools(environment):
    if environment.get("SPARKLE_BIN_DIR"):
        directory = Path(environment["SPARKLE_BIN_DIR"])
    else:
        root = Path(environment.get("CI_DERIVED_DATA_PATH", "/nonexistent"))
        matches = list(root.glob("SourcePackages/artifacts/sparkle/**/bin/generate_appcast"))
        if len(matches) != 1:
            raise ReleaseError("Cannot locate Sparkle tools; configure SPARKLE_BIN_DIR")
        directory = matches[0].parent
    if not all((directory / name).is_file() for name in ("generate_appcast", "sign_update")):
        raise ReleaseError("Sparkle tools are missing from SPARKLE_BIN_DIR")
    return directory


def generate_feed(directory, tools, secret, snapshot, archive, build, tag, url, preview):
    feed = directory / "appcast.xml"
    if snapshot:
        feed.write_bytes(snapshot)
    elif feed.exists():
        feed.unlink()
    arguments = [tools / "generate_appcast", "--ed-key-file", "-", "--maximum-deltas", "0", "--maximum-versions", "0",
                 "--versions", build, "--download-url-prefix", url.rsplit("/", 1)[0] + "/",
                 "--release-notes-url-prefix", FEED_URL.rsplit("/", 1)[0] + "/", directory]
    if preview:
        arguments += ["--channel", "preview"]
    run(arguments, secret=secret + "\n")
    root, item = validate_feed(feed.read_bytes(), build, tag, archive, url, preview)
    item.find(f"{{{SPARKLE}}}shortVersionString").text = tag.removeprefix("v")
    item.find("title").text = f"MarkLens {tag.removeprefix('v')}"
    feed.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))
    # Verify the emitted archive signature; a mismatched bundle public key produces no signature.
    run([tools / "sign_update", "--ed-key-file", "-", "--verify", archive,
         item.find("enclosure").get(f"{{{SPARKLE}}}edSignature")], secret=secret + "\n")
    return feed.read_bytes()


def notarize_app(app, environment):
    """Replace the Cloud Notarize post-action with one synchronous submission."""
    try:
        run(["xcrun", "stapler", "validate", app])
        return
    except ReleaseError:
        pass
    private_key = environment.get("APP_STORE_CONNECT_API_PRIVATE_KEY")
    key_id = environment.get("APP_STORE_CONNECT_API_KEY_ID")
    issuer_id = environment.get("APP_STORE_CONNECT_API_ISSUER_ID")
    if not all((private_key, key_id, issuer_id)):
        raise ReleaseError(
            "Configure these Xcode Cloud variables for scripted notarization: "
            "APP_STORE_CONNECT_API_PRIVATE_KEY (secret), APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID "
            "to notarize before publishing."
        )
    with tempfile.TemporaryDirectory(prefix="marklens-notarization-") as temporary:
        directory = Path(temporary)
        key_file = directory / "AuthKey.p8"
        descriptor = os.open(key_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as file:
            file.write(private_key.strip() + "\n")
        print("Submitting the signed app for notarization; waiting up to 20 minutes for Apple.", flush=True)
        submission = directory / "MarkLens-notarization.zip"
        run(["ditto", "-c", "-k", "--keepParent", app, submission])
        result = run([
            "xcrun", "notarytool", "submit", submission, "--key", key_file,
            "--key-id", key_id, "--issuer", issuer_id, "--wait", "--timeout", "20m",
            "--output-format", "json",
        ])
        try:
            accepted = json.loads(result).get("status") == "Accepted"
        except (ValueError, AttributeError):
            accepted = False
        if not accepted:
            raise ReleaseError("Apple did not accept the notarization submission; no update was published")
        run(["xcrun", "stapler", "staple", app])
        run(["xcrun", "stapler", "validate", app])
        print("Notarization accepted and ticket stapled; preparing the Sparkle update.", flush=True)


def publish(environment=os.environ):
    tag = environment.get("CI_TAG", "").removeprefix("refs/tags/")
    if (environment.get("CI_XCODEBUILD_ACTION") != "archive"
            or environment.get("CI_XCODEBUILD_EXIT_CODE", "1") != "0"
            or not tag or "-test" in tag):
        print("Not a successful release archive; skipping update publication.")
        return
    match = TAG_PATTERN.fullmatch(tag)
    if not match:
        raise ReleaseError("CI_TAG is not a supported release tag")
    base, suffix = match.groups()
    preview = suffix is not None
    token = environment.get("GITHUB_RELEASE_TOKEN")
    secret = environment.get("SPARKLE_PRIVATE_KEY")
    if not token or not secret:
        raise ReleaseError("GITHUB_RELEASE_TOKEN and SPARKLE_PRIVATE_KEY must be configured as Xcode Cloud secrets")
    tools = find_sparkle_tools(environment)
    artifact = Path(environment.get("CI_DEVELOPER_ID_SIGNED_APP_PATH", "/nonexistent"))
    app = artifact if artifact.suffix == ".app" else artifact / "MarkLens.app"
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ReleaseError("Cannot read the exported MarkLens.app") from error
    commit = environment.get("CI_COMMIT", "")
    if (info.get("CFBundleIdentifier") != "ch.doapp.MarkLens"
            or not re.fullmatch(r"[0-9a-fA-F]{40}", commit)
            or info.get("MarkLensReleaseCommit") != commit):
        raise ReleaseError("Exported app identity or signed source commit does not match this release")
    build = str(info.get("CFBundleVersion", ""))
    if not build.isdecimal() or int(build) < 1 or info.get("CFBundleShortVersionString") != base:
        raise ReleaseError("App version does not match the release tag or has an invalid build number")
    try:
        public_key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except ValueError:
        public_key = b""
    if len(public_key) != 32 or info.get("SUFeedURL") != FEED_URL:
        raise ReleaseError("Exported app is missing its Sparkle public key or expected feed URL")
    if info.get("SURequireSignedFeed"):
        raise ReleaseError("Feed signing requires a coordinated pipeline change; this pipeline signs update archives")
    extension = app / "Contents/PlugIns/QuickLookPreview_macOS.appex"
    if not extension.is_dir() or not (app / "Contents/Frameworks/Sparkle.framework").is_dir():
        raise ReleaseError("Exported app is missing Quick Look or Sparkle")
    run(["codesign", "--verify", "--deep", "--strict", app])
    notarize_app(app, environment)
    run(["spctl", "--assess", "--type", "execute", app])
    repository = environment.get("GITHUB_REPOSITORY", "pd95/MarkLens")
    github = GitHub(repository, token, environment.get("GITHUB_API_URL", "https://api.github.com"),
                    environment.get("GITHUB_UPLOADS_URL", "https://uploads.github.com"))
    changelog = Path(environment.get("CHANGELOG_FILE", Path(__file__).resolve().parent.parent / "CHANGELOG.md"))
    notes = changelog_notes(changelog.read_text(), base).encode()
    with tempfile.TemporaryDirectory(prefix="marklens-update-") as temporary:
        directory = Path(temporary)
        archive = directory / f"MarkLens-{tag}.zip"
        url = f"https://github.com/{repository}/releases/download/{tag}/{archive.name}"
        head, tree, snapshot = github.feed_snapshot()
        ensure_increasing(snapshot, build, tag, url)
        run(["ditto", "-c", "-k", "--keepParent", app, archive])
        note_name = f"MarkLens-{tag}.md"
        (directory / note_name).write_bytes(notes)
        # Generate before any remote mutation, to catch signing-key/configuration errors early.
        generate_feed(directory, tools, secret, snapshot, archive, build, tag, url, preview)
        sections = notes.decode().split("## Version ")[1:]
        body = next(section.partition("\n")[2].strip() for section in sections
                    if section.partition("\n")[0] == base)
        if environment.get("CI_BUILD_URL"):
            body += "\n\nXcode Cloud build: " + environment["CI_BUILD_URL"]
        release = github.release(tag, preview, body)
        if release.get("draft") or release.get("prerelease") != preview:
            raise ReleaseError("Existing GitHub Release has incompatible draft/channel metadata")
        github.upload_archive(release, archive, tag)
        for attempt in range(3):
            ensure_increasing(snapshot, build, tag, url)
            feed = generate_feed(directory, tools, secret, snapshot, archive, build, tag, url, preview)
            try:
                github.publish_files(head, tree, {FEED_PATH: feed, f"updates/{note_name}": notes, ".nojekyll": b""})
                print(f"Published signed update {tag} (build {build}); verify GitHub Pages deployment.")
                return
            except APIError as error:
                if error.status not in (409, 422) or attempt == 2:
                    raise
                head, tree, snapshot = github.feed_snapshot()
        raise ReleaseError("Concurrent feed publication did not converge")


if __name__ == "__main__":
    try:
        publish()
    except (ReleaseError, OSError, ValueError, KeyError, urllib.error.URLError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
