import base64
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("release_updates", Path(__file__).resolve().parents[1] / "release_updates.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

TAG = "v1.10.0-rc2"
URL = f"https://github.com/pd95/MarkLens/releases/download/{TAG}/MarkLens-{TAG}.zip"
SIGNATURE = base64.b64encode(bytes(64)).decode()


def feed(build="102", tag=TAG, url=URL, preview=True, size=3, signature=SIGNATURE):
    channel = "<sparkle:channel>preview</sparkle:channel>" if preview else ""
    return f'''<rss xmlns:sparkle="{release.SPARKLE}" version="2.0"><channel><item>
        <title>MarkLens</title><sparkle:version>{build}</sparkle:version>
        <sparkle:shortVersionString>{tag.removeprefix('v')}</sparkle:shortVersionString>{channel}
        <sparkle:minimumSystemVersion>15.6</sparkle:minimumSystemVersion>
        <enclosure url="{url}" length="{size}" sparkle:edSignature="{signature}"/>
        </item></channel></rss>'''.encode()


class ReleaseUpdatesTests(unittest.TestCase):
    def test_notes_cover_only_target_and_previous_versions(self):
        notes = release.changelog_notes("## 2.0.0\nFuture\n## [1.10.0] (Unreleased)\nNew\n## 1.9.1\nPatch\n## Notes\nOther\n", "1.10.0")
        self.assertEqual(notes, "## Version 1.10.0\n\nNew\n\n## Version 1.9.1\n\nPatch\n")
        with self.assertRaises(release.ReleaseError):
            release.changelog_notes("## 1.9.1\nOld", "1.10.0")

    def test_ordering_covers_both_channels_and_allows_identical_retry(self):
        release.ensure_increasing(feed(), "102", TAG, URL)
        release.ensure_increasing(feed(), "103", "v1.10.0", URL.replace(TAG, "v1.10.0"))
        for build in ["100", "102"]:
            with self.assertRaises(release.ReleaseError):
                release.ensure_increasing(feed(), build, "v1.10.0", URL.replace(TAG, "v1.10.0"))
        with self.assertRaises(release.ReleaseError):
            release.ensure_increasing(feed(), "103", TAG, URL)
        with self.assertRaises(release.ReleaseError):
            release.ensure_increasing(b"bad XML", "103", TAG, URL)

    def test_higher_build_cannot_offer_older_marketing_version(self):
        for tag in ["v1.9.2", "v1.10.0-rc1"]:
            with self.assertRaises(release.ReleaseError):
                release.ensure_increasing(feed(), "103", tag, URL.replace(TAG, tag))
        release.ensure_increasing(feed(tag="v1.10.0-rc9"), "103", "v1.10.0-rc10", URL + "new")
        with self.assertRaises(release.ReleaseError):
            release.ensure_increasing(feed(tag="v1.10.0", preview=False), "103", TAG, URL + "new")

    def test_feed_rejects_unsigned_wrong_size_url_and_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "MarkLens.zip"
            archive.write_bytes(b"zip")
            release.validate_feed(feed(), "102", TAG, archive, URL, True)
            for invalid in [feed(signature=""), feed(size=99), feed(url="https://attacker.example/app.zip"), feed(preview=False)]:
                with self.assertRaises(release.ReleaseError):
                    release.validate_feed(invalid, "102", TAG, archive, URL, True)

    def test_eligibility_never_publishes_failed_untagged_or_test_builds(self):
        for env in [{}, {"CI_XCODEBUILD_ACTION": "test"},
                    {"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "1", "CI_TAG": TAG},
                    {"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0", "CI_TAG": "v1.10.0-test1"}]:
            with patch.object(release, "GitHub") as github:
                release.publish(env)
                github.assert_not_called()

    def test_missing_keys_fail_before_remote_mutations(self):
        with patch.object(release, "GitHub") as github:
            with self.assertRaises(release.ReleaseError):
                release.publish({"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0", "CI_TAG": TAG})
            github.assert_not_called()

    def test_published_archive_is_never_deleted_or_replaced(self):
        github = release.GitHub("pd95/MarkLens", "token")
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / f"MarkLens-{TAG}.zip"
            archive.write_bytes(b"zip")
            asset = {"name": archive.name, "state": "uploaded", "browser_download_url": URL}
            with patch.object(github, "assets", return_value=[asset]), patch.object(github, "request") as request:
                with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b"zip")):
                    self.assertEqual(github.upload_archive({"id": 1}, archive, TAG), URL)
                with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b"different")):
                    with self.assertRaises(release.ReleaseError):
                        github.upload_archive({"id": 1}, archive, TAG)
                request.assert_not_called()

    def test_upload_race_verifies_remote_bytes(self):
        github = release.GitHub("pd95/MarkLens", "token")
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / f"MarkLens-{TAG}.zip"
            archive.write_bytes(b"zip")
            asset = {"name": archive.name, "state": "uploaded", "browser_download_url": URL}
            with patch.object(github, "assets", side_effect=[[], [asset]]), \
                 patch.object(github, "request", side_effect=release.APIError(422, "upload")), \
                 patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b"zip")):
                self.assertEqual(github.upload_archive({"id": 1}, archive, TAG), URL)

    def test_ref_publication_is_nonforcing_and_preserves_other_files(self):
        github = release.GitHub("pd95/MarkLens", "token")
        with patch.object(github, "request", side_effect=[{"sha": "blob"}, {"sha": "tree"}, {"sha": "commit"}, {}]) as request:
            github.publish_files("parent", "base-tree", {release.FEED_PATH: b"feed"})
            calls = request.call_args_list
            self.assertEqual(calls[1].args[2]["base_tree"], "base-tree")
            self.assertEqual(calls[2].args[2]["parents"], ["parent"])
            self.assertEqual(calls[3].args, ("PATCH", "git/refs/heads/gh-pages", {"sha": "commit", "force": False}))

    def test_api_token_is_a_header_and_never_part_of_url(self):
        github = release.GitHub("pd95/MarkLens", "secret-token")
        with patch.object(release.urllib.request, "urlopen", return_value=io.BytesIO(b'{"id":1}')) as urlopen:
            github.request("GET", "releases/tags/v1.10.0")
            request = urlopen.call_args.args[0]
            self.assertNotIn("secret-token", request.full_url)
            self.assertEqual(request.get_header("Authorization"), "Bearer secret-token")

    def test_signing_secret_is_only_sent_to_standard_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            archive = directory / f"MarkLens-{TAG}.zip"
            archive.write_bytes(b"zip")
            def fake_run(args, *, secret=None):
                self.assertNotIn("private-key", [str(a) for a in args])
                self.assertEqual(secret, "private-key\n")
                if Path(args[0]).name == "generate_appcast":
                    (directory / "appcast.xml").write_bytes(feed())
                return ""
            with patch.object(release, "run", side_effect=fake_run):
                result = release.generate_feed(directory, directory, "private-key", None, archive, "102", TAG, URL, True)
            item = ET.fromstring(result).find("./channel/item")
            self.assertEqual(item.findtext(f"{{{release.SPARKLE}}}shortVersionString"), "1.10.0-rc2")

    def run_publication(self, *, fail_upload=False, race=False, fail_notarization=False, bad_commit=False, bad_identity=False):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            app = directory / "MarkLens.app"
            (app / "Contents/PlugIns/QuickLookPreview_macOS.appex").mkdir(parents=True)
            (app / "Contents/Frameworks/Sparkle.framework").mkdir(parents=True)
            info = {"CFBundleIdentifier": "wrong.app" if bad_identity else "ch.doapp.MarkLens", "MarkLensReleaseCommit": "b" * 40 if bad_commit else "a" * 40, "CFBundleVersion": "102", "CFBundleShortVersionString": "1.10.0",
                    "SUPublicEDKey": base64.b64encode(bytes(32)).decode(), "SUFeedURL": release.FEED_URL}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            changelog = directory / "CHANGELOG.md"
            changelog.write_text("## 1.10.0\nNew\n## 1.9.1\nOld\n")
            environment = {"CI_XCODEBUILD_ACTION": "archive", "CI_XCODEBUILD_EXIT_CODE": "0", "CI_TAG": TAG,
                           "GITHUB_RELEASE_TOKEN": "token", "SPARKLE_PRIVATE_KEY": "secret", "CI_COMMIT": "a" * 40,
                           "CI_DEVELOPER_ID_SIGNED_APP_PATH": str(app), "CHANGELOG_FILE": str(changelog)}
            def fake_run(args, *, secret=None):
                if args[:3] == ["xcrun", "stapler", "validate"] and fail_notarization:
                    raise release.ReleaseError("Not notarized")
                if args[0] == "ditto":
                    Path(args[-1]).write_bytes(b"zip")
                return ""
            with patch.object(release, "run", side_effect=fake_run), \
                 patch.object(release, "find_sparkle_tools", return_value=directory), \
                 patch.object(release, "generate_feed", return_value=feed()), \
                 patch.object(release, "GitHub") as cls:
                github = cls.return_value
                github.feed_snapshot.side_effect = [(None, None, None), ("new-parent", "new-tree", None)]
                github.release.return_value = {"id": 1, "draft": False, "prerelease": True}
                if fail_upload:
                    github.upload_archive.side_effect = release.ReleaseError("Upload failed")
                if race:
                    github.publish_files.side_effect = [release.APIError(422, "update ref"), None]
                if fail_upload or fail_notarization or bad_commit or bad_identity:
                    with self.assertRaises(release.ReleaseError):
                        release.publish(environment)
                    github.publish_files.assert_not_called()
                    if fail_notarization or bad_commit or bad_identity:
                        github.release.assert_not_called()
                else:
                    release.publish(environment)
                    self.assertEqual(github.publish_files.call_count, 2 if race else 1)
                    if race:
                        self.assertEqual(github.publish_files.call_args.args[:2], ("new-parent", "new-tree"))
                    self.assertEqual(github.release.call_args.args, (TAG, True, "New"))
                    files = github.publish_files.call_args.args[2]
                    self.assertIn(".nojekyll", files)
                    self.assertIn(release.FEED_PATH, files)
                    self.assertIn(f"updates/MarkLens-{TAG}.md", files)

    def test_bundle_identity_mismatch_prevents_publication(self):
        self.run_publication(bad_identity=True)

    def test_embedded_release_commit_mismatch_prevents_publication(self):
        self.run_publication(bad_commit=True)

    def test_failed_upload_leaves_feed_unchanged(self):
        self.run_publication(fail_upload=True)

    def test_notarization_failure_prevents_release_creation(self):
        self.run_publication(fail_notarization=True)

    def test_concurrent_feed_publication_refetches_and_retries(self):
        self.run_publication(race=True)

    def test_successful_release_publishes_archive_then_feed(self):
        self.run_publication()


if __name__ == "__main__":
    unittest.main()
