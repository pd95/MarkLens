#!/usr/bin/env python3
"""Developer ID export tests without signing infrastructure or real credentials."""
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_updates as release

KEY = "-----BEGIN PRIVATE KEY-----\nexport-private-secret\n-----END PRIVATE KEY-----"
AUTH = {"APP_STORE_CONNECT_API_PRIVATE_KEY": KEY, "APP_STORE_CONNECT_API_KEY_ID": "KEYID",
        "APP_STORE_CONNECT_API_ISSUER_ID": "issuer", "CI_TEAM_ID": "ABCDEFGHIJ"}


class ExportTests(unittest.TestCase):
    def exercise_export(self, *, configured=None, fail=False, consumer_failure=False, team="ABCDEFGHIJ"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "MarkLens.xcarchive"
            archive.mkdir()
            environment = dict(AUTH, CI_ARCHIVE_PATH=str(archive))
            if team is None:
                environment.pop("CI_TEAM_ID", None)
            else:
                environment["CI_TEAM_ID"] = team
            if configured is not None:
                directory = root / "configured"
                if configured == "empty":
                    directory.mkdir()
                environment["CI_DEVELOPER_ID_SIGNED_APP_PATH"] = str(directory)
            calls, keys, exports = [], [], []
            def fake_run(args, *, secret=None):
                calls.append(args)
                self.assertEqual(args[:2], ["xcodebuild", "-exportArchive"])
                self.assertEqual(args[args.index("-archivePath") + 1], str(archive))
                self.assertIn("-allowProvisioningUpdates", args)
                options = plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
                self.assertEqual(options, {"method": "developer-id", "destination": "export", "signingStyle": "automatic",
                                           "manageAppVersionAndBuildNumber": False})
                key = Path(args[args.index("-authenticationKeyPath") + 1])
                keys.append(key)
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertEqual(key.read_text(), KEY + "\n")
                self.assertNotIn("export-private-secret", " ".join(map(str, args)))
                self.assertEqual(args[args.index("-authenticationKeyID") + 1], "KEYID")
                self.assertEqual(args[args.index("-authenticationKeyIssuerID") + 1], "issuer")
                destination = Path(args[args.index("-exportPath") + 1])
                exports.append(destination)
                if fail:
                    raise release.ReleaseError("Export failed")
                (destination / "MarkLens.app").mkdir(parents=True)
                return ""
            with patch.object(release, "run", side_effect=fake_run):
                if fail or consumer_failure:
                    with self.assertRaises(release.ReleaseError):
                        with release.exported_app(environment) as app:
                            self.assertTrue(app.is_dir())
                            self.assertFalse(keys[0].exists())
                            raise release.ReleaseError("Consumer failed")
                else:
                    with release.exported_app(environment) as app:
                        self.assertTrue(app.is_dir())
                        self.assertEqual(app, exports[0] / "MarkLens.app")
                        self.assertFalse(keys[0].exists())
            self.assertEqual(len(calls), 1)
            self.assertFalse(keys[0].parent.exists())
            self.assertFalse(exports[0].parent.exists())

    def test_archive_only_export_options_and_secret_lifetime(self):
        self.exercise_export()

    def test_empty_or_missing_configured_export_falls_back_to_archive(self):
        self.exercise_export(configured="empty")
        self.exercise_export(configured="missing")

    def test_export_failure_and_consumer_exception_clean_resources(self):
        self.exercise_export(fail=True)
        self.exercise_export(consumer_failure=True)

    def test_existing_export_reused_without_credentials_or_commands(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "MarkLens.app"
            app.mkdir()
            for path in [app, root]:
                with patch.object(release, "run") as run:
                    with release.exported_app({"CI_DEVELOPER_ID_SIGNED_APP_PATH": str(path)}) as selected:
                        self.assertEqual(selected, app)
                    run.assert_not_called()
            self.assertTrue(app.exists())

    def test_export_uses_archive_team_instead_of_ci_environment_team(self):
        for team in [None, "", "69a6de74-4168-47e3-e053-5b8c7c11a4d1"]:
            with self.subTest(team=team):
                self.exercise_export(team=team)

    def test_missing_archive_fails_before_export(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, "run") as run:
            for environment in [{}, {"CI_ARCHIVE_PATH": "/nonexistent"}]:
                with self.subTest(environment=environment), self.assertRaises(release.ReleaseError):
                    with release.exported_app(environment):
                        self.fail("Invalid export configuration was accepted")
            run.assert_not_called()

    def test_ambiguous_configured_export_fails_without_fallback(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, "run") as run:
            root = Path(temporary)
            (root / "MarkLens.app").mkdir()
            (root / "Other.app").mkdir()
            with self.assertRaises(release.ReleaseError):
                with release.exported_app({"CI_DEVELOPER_ID_SIGNED_APP_PATH": temporary}):
                    self.fail("Ambiguous bundles were accepted")
            run.assert_not_called()

    def test_failed_export_prevents_notarization_and_remote_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(AUTH, CI_ARCHIVE_PATH=temporary, CI_TAG="v1.10.0-rc1",
                               CI_XCODEBUILD_ACTION="archive", CI_XCODEBUILD_EXIT_CODE="0",
                               GITHUB_RELEASE_TOKEN="token", SPARKLE_PRIVATE_KEY="sparkle-key")
            with patch.object(release, "find_sparkle_tools", return_value=Path(temporary)), \
                 patch.object(release, "run", side_effect=release.ReleaseError("Export failed")), \
                 patch.object(release, "notarize_app") as notarize, patch.object(release, "GitHub") as github:
                with self.assertRaises(release.ReleaseError):
                    release.publish(environment)
                notarize.assert_not_called()
                github.assert_not_called()


if __name__ == "__main__":
    unittest.main()
