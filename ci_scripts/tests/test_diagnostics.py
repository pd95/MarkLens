#!/usr/bin/env python3
"""Keep useful export failures while removing credentials from tool diagnostics."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_updates as release

KEY = "-----BEGIN PRIVATE KEY-----\nprivate-base64-line-one\nprivate-base64-line-two\n-----END PRIVATE KEY-----"
AUTH = {"APP_STORE_CONNECT_API_PRIVATE_KEY": KEY, "APP_STORE_CONNECT_API_KEY_ID": "KEY1234567",
        "APP_STORE_CONNECT_API_ISSUER_ID": "issuer-value", "SPARKLE_PRIVATE_KEY": "sparkle-private-value",
        "GITHUB_RELEASE_TOKEN": "github-token-value"}


class DiagnosticsTests(unittest.TestCase):
    def test_redacts_credentials_in_pem_json_and_individual_lines(self):
        output = "error: exportArchive No signing certificate found\n" + KEY + "\n" + json.dumps(KEY)
        output += "\nprivate-base64-line-one\nprivate-base64-line-twoprivate-base64-line-one\n"
        output += "\n".join(AUTH.values()) + "\nAuthorization: Bearer unlisted.jwt.token"
        redacted = release.redacted_diagnostics(output, AUTH)
        self.assertIn("error: exportArchive No signing certificate found", redacted)
        for secret in [*AUTH.values(), "private-base64-line-one", "private-base64-line-two", "unlisted.jwt.token"]:
            self.assertNotIn(secret, redacted)

    def test_redacts_before_truncating_and_bounds_output(self):
        secret = "x" * 25000
        output = release.redacted_diagnostics("error\n" + secret + "\nend", {"SOME_SECRET": secret})
        self.assertEqual(output, "error\n[REDACTED]\nend")
        self.assertLessEqual(len(release.redacted_diagnostics("z" * 40000, {})), 20000)

    def test_run_exception_message_does_not_include_raw_output(self):
        result = subprocess.CompletedProcess(["xcodebuild"], 70, stdout=KEY, stderr="export failed")
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ToolError) as raised:
                release.run(["xcodebuild", "-exportArchive"])
        self.assertEqual(str(raised.exception), "xcodebuild failed (exit 70)")
        self.assertIn("export failed", raised.exception.output)
        self.assertNotIn("private-base64", str(raised.exception))

    def test_failed_export_logs_actual_error_redacts_secrets_and_cleans_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(AUTH, CI_ARCHIVE_PATH=temporary)
            keys = []
            def fail_export(args, **kwargs):
                keys.append(Path(args[args.index("-authenticationKeyPath") + 1]))
                return subprocess.CompletedProcess(args, 70, stdout="Export failed\n" + KEY,
                    stderr="error: exportArchive No signing certificate found\n" + AUTH["GITHUB_RELEASE_TOKEN"])
            output = io.StringIO()
            with patch.object(release.subprocess, "run", side_effect=fail_export), contextlib.redirect_stderr(output):
                with self.assertRaisesRegex(release.ReleaseError, "redacted Xcode diagnostics"):
                    with release.exported_app(environment):
                        self.fail("Failed export was accepted")
            self.assertIn("error: exportArchive No signing certificate found", output.getvalue())
            for secret in [KEY, "private-base64-line-one", AUTH["GITHUB_RELEASE_TOKEN"]]:
                self.assertNotIn(secret, output.getvalue())
            self.assertFalse(keys[0].exists())
            self.assertFalse(keys[0].parent.exists())

    def test_publisher_reports_other_tool_failures_with_redaction(self):
        result = subprocess.CompletedProcess(["xcrun"], 1, stdout="Notarization failed", stderr=KEY)
        error = release.ToolError("xcrun", result)
        output = io.StringIO()
        with patch.object(release, "_publish", side_effect=error), contextlib.redirect_stderr(output):
            with self.assertRaises(release.ToolError):
                release.publish(AUTH)
        self.assertIn("Notarization failed", output.getvalue())
        self.assertNotIn("private-base64-line-one", output.getvalue())


if __name__ == "__main__":
    unittest.main()
