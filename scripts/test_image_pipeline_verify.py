"""Exercise the image release gate with local, disposable HTTP and DB fakes."""

from contextlib import closing
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GIT_BASH = Path(r"C:\Program Files\Git\bin\bash.exe")
BASH = str(GIT_BASH) if os.name == "nt" and GIT_BASH.exists() else shutil.which("bash")


@unittest.skipUnless(BASH, "bash is required")
class ImagePipelineGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="image-gate-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.database = self.directory / "test.sqlite"
        self.calls = self.directory / "urls.txt"
        with closing(sqlite3.connect(self.database)) as db:
            db.executescript("""
                CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT, mime_type TEXT,
                    access_scope TEXT, width INTEGER, height INTEGER);
                CREATE TABLE image_variants (file_id INTEGER, recipe_version INTEGER, status TEXT);
                INSERT INTO files VALUES (1, '/uploads/example.gif', 'image/gif', 'public', 300, 300);
                INSERT INTO files VALUES (2, '/uploads/example.jpg', 'image/jpeg', 'public', 300, 300);
                INSERT INTO image_variants VALUES (1, 1, 'pending');
                INSERT INTO image_variants VALUES (1, 1, 'failed');
                INSERT INTO image_variants VALUES (1, 2, 'ready');
                INSERT INTO image_variants VALUES (2, 1, 'ready');
            """)
        psql_python = self.directory / "psql_mock.py"
        psql_python.write_text(
            "import os, sqlite3, sys\n"
            "db = sqlite3.connect(os.environ['MOCK_DB'])\n"
            "db.create_function('GREATEST', 2, max)\n"
            "rows = db.execute(sys.argv[-1]).fetchall()\n"
            "for row in rows: print('|'.join(str(value) for value in row))\n",
            encoding="utf-8",
        )
        self._write_executable("psql_mock", '#!/usr/bin/env bash\nexec "$MOCK_PYTHON" "$MOCK_PSQL" "$@"\n')
        self._write_executable("mock_curl", """curl() {
url="${@: -1}"
printf '%s\\n' "$url" >> "$MOCK_URLS"
case "$url" in
  */private.jpg|*/_internal/*|*/etc/passwd) code=404 ;;
  */example.gif|*/example.jpg|*/example_v2_thumb.png|*/example_v2_medium.png|*/example_v1_thumb.jpg|*/example_v1_medium.jpg) code=200 ;;
  *) code=404 ;;
esac
if [[ " $* " == *" -D - "* ]]; then
  printf 'HTTP/1.1 %s Test\\r\\nCache-Control: public, max-age=86400\\r\\n\\r\\n' "$code"
else
  printf '%s' "$code"
fi
}
""")
        self.env = dict(
            os.environ,
            PATH=str(self.directory) + os.pathsep + os.environ.get("PATH", ""),
            BASE_URL="https://unit.invalid",
            PUBLIC_URL="https://unit.invalid/uploads/example.gif",
            PRIVATE_URL="https://unit.invalid/uploads/private.jpg",
            VARIANT_WAIT_SECONDS="0",
            PSQL_CMD=str(self.directory / "psql_mock").replace("\\", "/"),
            BASH_ENV=str(self.directory / "mock_curl").replace("\\", "/"),
            MOCK_DB=str(self.database),
            MOCK_URLS=str(self.calls).replace("\\", "/"),
            MOCK_PYTHON=sys.executable,
            MOCK_PSQL=str(psql_python),
        )

    def _write_executable(self, name, text):
        path = self.directory / name
        path.write_text(text, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_gate(self):
        return subprocess.run(
            [BASH, str(ROOT / "scripts" / "image_pipeline_verify.sh")],
            cwd=ROOT,
            env=self.env,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=30,
        )

    def test_gif_current_recipe_is_checked_and_old_jobs_do_not_block(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        urls = self.calls.read_text(encoding="utf-8")
        self.assertIn("example_v2_thumb.png", urls)
        self.assertIn("example_v2_medium.png", urls)
        self.assertNotIn("example_v1_thumb.gif", urls)

    def test_missing_current_gif_tasks_fail_even_if_legacy_exists(self):
        with closing(sqlite3.connect(self.database)) as db:
            db.execute("DELETE FROM image_variants WHERE file_id = 1 AND recipe_version = 2")
            db.commit()
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("public_without_any_variant=1", result.stdout)

    def test_current_failure_fails_closed_and_jpeg_keeps_v1(self):
        with closing(sqlite3.connect(self.database)) as db:
            db.execute("UPDATE image_variants SET status = 'failed' WHERE file_id = 1 AND recipe_version = 2")
            db.commit()
        self.env["PUBLIC_URL"] = "https://unit.invalid/uploads/example.jpg"
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("failed=1", result.stdout)
        self.assertIn("example_v1_thumb.jpg", self.calls.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
