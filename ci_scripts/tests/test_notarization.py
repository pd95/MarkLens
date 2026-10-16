#!/usr/bin/env python3
"""Test publication's notarization gate without Apple network or credentials."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_updates as release

PRIVATE_KEY = "-----BEGIN PRIVATE KEY-----\nsecret-key-content\n-----END PRIVATE KEY-----"
CREDENTIALS = {"APP_STORE_CONNECT_API_PRIVATE_KEY": PRIVATE_KEY,
               "APP_STORE_CONNECT_API_KEY_ID": "KEYID", "APP_STORE_CONNECT_API_ISSUER_ID": "issuer"}


class NotarizationTests(unittest.TestCase):
    def test_tool_error_never_echoes_secret_output(self):
        failure = subprocess.CompletedProcess(["xcrun"], 1, stdout=PRIVATE_KEY, stderr=PRIVATE_KEY)
        with patch.object(release.subprocess, "run", return_value=failure):
            with self.assertRaises(release.ReleaseError) as error:
                release.run(["xcrun", "notarytool", "submit"])
        self.assertNotIn("secret-key-content", str(error.exception))

    def test_stapled_app_needs_no_credentials_or_submission(self):
        with patch.object(release, "run", return_value="") as run:
            release.notarize_app(Path("MarkLens.app"), {})
        run.assert_called_once_with(["xcrun", "stapler", "validate", Path("MarkLens.app")])

    def test_unstapled_app_requires_complete_credentials(self):
        for credentials in [{}, *[{k: v for k, v in CREDENTIALS.items() if k != missing} for missing in CREDENTIALS]]:
            with self.subTest(keys=list(credentials)), patch.object(release, "run", side_effect=release.ReleaseError("No ticket")) as run:
                with self.assertRaises(release.ReleaseError):
                    release.notarize_app(Path("MarkLens.app"), credentials)
                self.assertEqual(run.call_count, 1)

    def exercise(self, *, response='{"status":"Accepted"}', fail_tool=False, accepted=True):
        calls = []
        key_paths = []
        output = io.StringIO()
        def fake_run(args, *, secret=None):
            calls.append(args)
            self.assertNotIn(PRIVATE_KEY, [str(a) for a in args])
            self.assertNotIn("secret-key-content", " ".join(str(a) for a in args))
            if len(calls) == 1:
                raise release.ReleaseError("No stapled ticket")
            if args[:3] == ["xcrun", "notarytool", "submit"]:
                key = Path(args[args.index("--key") + 1])
                key_paths.append(key)
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertEqual(key.read_text(), PRIVATE_KEY + "\n")
                self.assertIn("--wait", args)
                self.assertEqual(args[args.index("--output-format") + 1], "json")
                if fail_tool:
                    raise release.ReleaseError("Notary request failed")
                return response
            return ""
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), patch.object(release, "run", side_effect=fake_run):
            if accepted:
                release.notarize_app(Path("MarkLens.app"), CREDENTIALS)
            else:
                with self.assertRaises(release.ReleaseError) as error:
                    release.notarize_app(Path("MarkLens.app"), CREDENTIALS)
                self.assertNotIn("secret-key-content", str(error.exception))
        self.assertEqual(len(key_paths), 1)
        self.assertFalse(key_paths[0].exists())
        self.assertFalse(key_paths[0].parent.exists())
        self.assertNotIn("secret-key-content", output.getvalue())
        staple = [args for args in calls if args[:3] == ["xcrun", "stapler", "staple"]]
        self.assertEqual(bool(staple), accepted)
        if accepted:
            self.assertEqual(calls[-2][:3], ["xcrun", "stapler", "staple"])
            self.assertEqual(calls[-1][:3], ["xcrun", "stapler", "validate"])

    def test_acceptance_staples_then_validates_and_removes_private_key(self):
        self.exercise()

    def test_rejection_never_staples_and_removes_private_key(self):
        for response in ['{"status":"Invalid"}', '{"status":"In Progress"}', '{}', 'not-json', 'null']:
            with self.subTest(response=response):
                self.exercise(response=response, accepted=False)

    def test_tool_failure_removes_private_key_and_does_not_staple(self):
        self.exercise(fail_tool=True, accepted=False)


if __name__ == "__main__":
    unittest.main()
