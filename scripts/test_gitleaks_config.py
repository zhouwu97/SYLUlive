"""Exercise the real scanner so an empty ruleset cannot pass CI silently."""

import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class GitleaksConfigTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scanner = shutil.which("gitleaks")
        if not cls.scanner:
            raise RuntimeError("Install the CI-pinned gitleaks before running this check")

    def scan(self, path, content):
        with tempfile.TemporaryDirectory(prefix="sylulive-scanner-test-") as tmp:
            directory = pathlib.Path(tmp)
            source = directory / "source"
            fixture = source / path
            fixture.parent.mkdir(parents=True)
            fixture.write_text(content, encoding="utf-8")
            report = directory / "findings.json"
            result = subprocess.run(
                [self.scanner, "dir", "--no-banner", "--redact",
                 "--config", str(ROOT / ".gitleaks.toml"),
                 "--report-format", "json", "--report-path", str(report),
                 "."],
                cwd=source, capture_output=True, text=True, check=False,
            )
            self.assertIn(result.returncode, (0, 1), result.stderr)
            findings = json.loads(report.read_text(encoding="utf-8")) if report.exists() else []
            self.assertEqual(result.returncode, int(bool(findings)), result.stderr)
            return findings

    def test_plain_source_passes(self):
        self.assertEqual(self.scan("plain.ts", "export const count = 3;"), [])

    def test_private_key_detector_is_active_even_in_allowlisted_path(self):
        # This is deliberately invalid key data, with no usable credential.
        fixture = ("-----BEGIN " + "OPENSSH PRIVATE KEY-----\n"
                   "VGhpcyBpcyBhIHN5bnRoZXRpYyBub24tZnVuY3Rpb25hbCBzY2FuIHRlc3Qu\n"
                   "-----END " + "OPENSSH PRIVATE KEY-----\n")
        for path in ("sample.txt", "browser-extension/src/school.ts"):
            with self.subTest(path=path):
                rules = {row["RuleID"] for row in self.scan(path, fixture)}
                self.assertIn("private-key", rules)

    def test_public_protocol_exception_requires_both_value_and_path(self):
        value = "8d6c5b73a50d4707bd71c93882ddbc8b"
        fixture = f'const apiKey = "{value}";'
        self.assertEqual(self.scan("browser-extension/src/school.ts", fixture), [])
        self.assertTrue(self.scan("different.ts", fixture))
        other = "f48a71d9b60e325c" + "94ad801f9c73e62b"
        self.assertTrue(self.scan("browser-extension/src/school.ts",
                                  f'const apiKey = "{other}";'))

    def test_other_exceptions_cannot_hide_new_credentials_in_the_same_file(self):
        paths = (
            "server/cmd/paper_storage/main_test.go",
            "server/internal/config/config_test.go",
            "client/lib/services/emoji_favorite_service.dart",
            "knowledge-base/sylu-academic-policy/v0.6/release-manifest.v0.6.json",
            "docs/archive/2026-08-28/VERIFICATION_CHECKLIST.md",
        )
        value = "f48a71d9b60e325c" + "94ad801f9c73e62b"
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(self.scan(path, f'const apiKey = "{value}";'))


if __name__ == "__main__":
    unittest.main()
