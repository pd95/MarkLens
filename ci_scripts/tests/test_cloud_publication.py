#!/usr/bin/env python3
"""Release orchestration tests; no Apple/GitHub network or production credentials."""
import base64
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cloud_artifact as cloud
import prepare_notarized_app as prepare
import request_update_publication as dispatch
from release_updates import ReleaseError

REQUEST = {"CLOUD_BUILD_ID": "abc-123", "CLOUD_BUILD_NUMBER": "102",
           "RELEASE_TAG": "v1.10.0-rc1", "RELEASE_COMMIT": "a" * 40}
CREDENTIALS = {"APP_STORE_CONNECT_API_PRIVATE_KEY": "unused",
               "APP_STORE_CONNECT_API_KEY_ID": "KEYID", "APP_STORE_CONNECT_API_ISSUER_ID": "issuer"}


def client_for(build=None, reference=None, artifacts=None):
    client = Mock()
    attributes = {"number": 102, "executionProgress": "COMPLETE", "completionStatus": "SUCCEEDED"}
    attributes.update(build or {})
    ref = {"kind": "TAG", "canonicalName": "refs/tags/v1.10.0-rc1"}
    ref.update(reference or {})
    def get(path):
        if path.endswith("/sourceBranchOrTag"):
            return {"data": {"attributes": ref}}
        if path.startswith("ciArtifacts/"):
            return {"data": {"attributes": {"downloadUrl": "https://download.example/archive.zip"}}}
        return {"data": {"attributes": attributes}}
    client.get.side_effect = get
    def listing(path):
        if "/actions?" in path:
            return [{"id": "action", "attributes": {"actionType": "ARCHIVE", "completionStatus": "SUCCEEDED"}}]
        return artifacts if artifacts is not None else [{"id": "artifact", "attributes": {"fileType": "STAPLED_NOTARIZED_ARCHIVE"}}]
    client.list.side_effect = listing
    return client


class ArtifactTests(unittest.TestCase):
    def test_only_successfully_completed_builds_are_accepted(self):
        for status in ["FAILED", "ERRORED", "CANCELED", "SKIPPED"]:
            client = client_for({"completionStatus": status})
            with self.subTest(status=status), self.assertRaises(ReleaseError):
                cloud.wait_for_artifact(client, REQUEST, attempts=1, delay=0)
            client.list.assert_not_called()
        for progress in ["PENDING", "RUNNING"]:
            client = client_for({"executionProgress": progress})
            with self.subTest(progress=progress), patch.object(cloud.time, "sleep"), self.assertRaises(ReleaseError):
                cloud.wait_for_artifact(client, REQUEST, attempts=2, delay=0)
            client.list.assert_not_called()

    def test_identity_mismatches_are_rejected_before_download(self):
        for client in [client_for({"number": 103}), client_for({"isPullRequestBuild": True}),
                       client_for({"sourceCommit": {"commitSha": "b" * 40}}),
                       client_for(reference={"kind": "BRANCH"}),
                       client_for(reference={"canonicalName": "refs/tags/v1.9.0"})]:
            with self.assertRaises(ReleaseError):
                cloud.wait_for_artifact(client, REQUEST, attempts=1, delay=0)
            client.list.assert_not_called()

    def test_missing_pr_only_source_commit_does_not_block_tag_release(self):
        self.assertEqual(cloud.wait_for_artifact(client_for(), REQUEST, attempts=1),
                         "https://download.example/archive.zip")

    def test_completed_build_waits_for_late_stapled_artifact(self):
        client = client_for()
        original = client.list.side_effect
        count = 0
        def delayed(path):
            nonlocal count
            if "/artifacts?" in path:
                count += 1
                if count == 1:
                    return [{"id": "raw", "attributes": {"fileType": "ARCHIVE_EXPORT"}}]
            return original(path)
        client.list.side_effect = delayed
        with patch.object(cloud.time, "sleep") as sleep:
            self.assertEqual(cloud.wait_for_artifact(client, REQUEST, attempts=2, delay=7),
                             "https://download.example/archive.zip")
        sleep.assert_called_once_with(7)
        self.assertEqual(count, 2)

    def test_absent_or_ambiguous_artifacts_are_rejected(self):
        for artifacts in [[], [{"id": str(i), "attributes": {"fileType": "STAPLED_NOTARIZED_ARCHIVE"}}
                              for i in range(2)]]:
            with patch.object(cloud.time, "sleep"), self.assertRaises(ReleaseError):
                cloud.wait_for_artifact(client_for(artifacts=artifacts), REQUEST, attempts=1, delay=0)

    def test_pagination_and_api_credential_boundary(self):
        client = cloud.AppleCloud(CREDENTIALS)
        with patch.object(client, "get", side_effect=[{"data": [1], "links": {"next": "next"}}, {"data": [2]}]):
            self.assertEqual(client.list("first"), [1, 2])
        with patch.object(client, "bearer_token") as token, patch.object(cloud.urllib.request, "urlopen") as opened:
            for path in ["https://evil.example/v1/", "//evil.example/v1/"]:
                with self.assertRaises(ReleaseError):
                    client.get(path)
            token.assert_not_called()
            opened.assert_not_called()

    def test_download_does_not_receive_apple_authorization(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "archive.zip"
            with patch.object(cloud.urllib.request, "urlopen", return_value=io.BytesIO(b"archive")) as opened:
                cloud.download_artifact("https://download.example/archive.zip", destination)
            self.assertEqual(destination.read_bytes(), b"archive")
            opened.assert_called_once_with("https://download.example/archive.zip", timeout=120)
        for url in ["http://example.com/a", "https://user:password@example.com/a", "file:///tmp/a"]:
            with self.assertRaises(ReleaseError):
                cloud.download_artifact(url, "unused")

    def test_real_openssl_jwt_signature_and_refresh(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "key.pem"
            public = Path(tmp) / "public.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(public)], check=True, capture_output=True)
            client = cloud.AppleCloud(dict(CREDENTIALS, APP_STORE_CONNECT_API_PRIVATE_KEY=key.read_text()))
            with patch.object(cloud.time, "time", return_value=1000):
                token = client.bearer_token()
                self.assertEqual(client.bearer_token(), token)
            decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
            header, claims, signature = token.split(".")
            self.assertEqual(json.loads(decode(header))["alg"], "ES256")
            self.assertEqual(json.loads(decode(claims)), {"iss": "issuer", "iat": 1000, "exp": 1600, "aud": "appstoreconnect-v1"})
            raw = decode(signature)
            self.assertEqual(len(raw), 64)
            integers = []
            for part in [raw[:32], raw[32:]]:
                part = part.lstrip(b"\0") or b"\0"
                if part[0] & 0x80:
                    part = b"\0" + part
                integers.append(b"\x02" + bytes([len(part)]) + part)
            body = b"".join(integers)
            sig = Path(tmp) / "signature.der"
            sig.write_bytes(b"\x30" + bytes([len(body)]) + body)
            result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(sig)],
                                    input=f"{header}.{claims}".encode(), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with patch.object(cloud.time, "time", return_value=1580):
                refreshed = client.bearer_token()
            self.assertEqual(json.loads(decode(refreshed.split(".")[1]))["iat"], 1580)


class DispatchTests(unittest.TestCase):
    def test_invalid_publication_inputs_are_rejected(self):
        for field, value in [("CLOUD_BUILD_ID", "../bad"), ("CLOUD_BUILD_NUMBER", "NaN"),
                             ("RELEASE_TAG", "v1.10.0-test1"), ("RELEASE_COMMIT", "short")]:
            with self.subTest(field=field), self.assertRaises(ReleaseError):
                cloud.publication_request(dict(REQUEST, **{field: value}))

    def test_dispatch_only_successful_release_archives(self):
        for environment in [{}, {"CI_XCODEBUILD_ACTION": "test"},
                            {"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "1", "CI_TAG": "v1.10.0"},
                            {"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0", "CI_TAG": "v1.10.0-test1"}]:
            with patch.object(dispatch, "GitHub") as github:
                dispatch.request_publication(environment)
                github.assert_not_called()

    def test_dispatch_sends_exact_validated_build_identity(self):
        environment = {"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0", "CI_TAG": "refs/tags/" + REQUEST["RELEASE_TAG"],
                       "CI_BUILD_ID": REQUEST["CLOUD_BUILD_ID"], "CI_BUILD_NUMBER": REQUEST["CLOUD_BUILD_NUMBER"],
                       "CI_COMMIT": REQUEST["RELEASE_COMMIT"], "GITHUB_RELEASE_TOKEN": "secret"}
        with patch.object(dispatch, "GitHub") as github:
            dispatch.request_publication(environment)
        github.return_value.request.assert_called_once_with("POST", "dispatches", {
            "event_type": "publish-notarized-update", "client_payload": REQUEST})
        with patch.object(dispatch, "GitHub") as github, self.assertRaises(ReleaseError):
            dispatch.request_publication(dict(environment, GITHUB_RELEASE_TOKEN=""))
        github.assert_not_called()


class PrepareTests(unittest.TestCase):
    def run_preparation(self, *, identity="ch.doapp.MarkLens", build="102", count=1, fail_ticket=False, existing=False, commit="a" * 40):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "MarkLens.app"
            if existing:
                destination.mkdir()
            calls = []
            def fake_run(args):
                calls.append(args)
                if args[:3] == ["ditto", "-x", "-k"]:
                    for i in range(count):
                        info = Path(args[-1]) / str(i) / "MarkLens.app/Contents/Info.plist"
                        info.parent.mkdir(parents=True)
                        metadata = {"CFBundleIdentifier": identity, "CFBundleVersion": build}
                        if commit is not None:
                            metadata["MarkLensReleaseCommit"] = commit
                        info.write_bytes(plistlib.dumps(metadata))
                if fail_ticket and args[:3] == ["xcrun", "stapler", "validate"]:
                    raise ReleaseError("No stapled ticket")
                return ""
            with patch.object(prepare, "run", side_effect=fake_run):
                if count != 1 or identity != "ch.doapp.MarkLens" or build != "102" or fail_ticket or existing or commit != "a" * 40:
                    with self.assertRaises(ReleaseError):
                        prepare.prepare(Path("original.zip"), destination, "102", "a" * 40)
                    self.assertFalse(any(args[0] == "ditto" and args[1] != "-x" for args in calls))
                else:
                    prepare.prepare(Path("original.zip"), destination, "102", "a" * 40)
                    self.assertEqual(calls[-2][:3], ["xcrun", "stapler", "validate"])
                    self.assertEqual(calls[-1][0], "ditto")

    def test_rejects_missing_ambiguous_wrong_identity_or_build(self):
        for options in [{"count": 0}, {"count": 2}, {"identity": "wrong.app"}, {"build": "103"}]:
            with self.subTest(options=options):
                self.run_preparation(**options)

    def test_requires_matching_embedded_release_commit(self):
        self.run_preparation(commit="b" * 40)
        self.run_preparation(commit=None)

    def test_requires_stapled_ticket_and_empty_destination(self):
        self.run_preparation(fail_ticket=True)
        self.run_preparation(existing=True)

    def test_preserves_bundle_only_after_verification(self):
        self.run_preparation()


if __name__ == "__main__":
    unittest.main()
