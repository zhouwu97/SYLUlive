"""identity_preflight 的只读和脱敏回归测试。"""

from __future__ import annotations

import contextlib
import io
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import identity_preflight as preflight


class IdentityPreflightTest(unittest.TestCase):
    def _database(self, directory: Path) -> Path:
        path = directory / "snapshot with spaces.db"
        connection = sqlite3.connect(path)
        connection.execute(
            "CREATE TABLE users ("
            "id INTEGER PRIMARY KEY, email TEXT, email_verified_at TEXT, qq TEXT, "
            "student_id TEXT, account_status TEXT, cancelled_at TEXT, role TEXT, "
            "edu_cleanup_pending INTEGER)"
        )
        connection.executemany(
            "INSERT INTO users VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (1, "Alice@Example.com", "2026-01-01", "", "", "active", None, "user", 0),
                (2, "alice@example.com", None, "", "", "active", None, "admin", 0),
                (3, "", None, "", "2026000001", "cancelled", "2026-02-01", "user", 1),
            ],
        )
        connection.commit()
        connection.close()
        return path

    def test_windows_style_sqlite_uri_is_read_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self._database(Path(directory))
            # sqlite:///C:/... 形式在 Windows 上会多一个盘符前导斜线；这里也覆盖
            # 当前平台的绝对路径和包含空格的 URI 编码。
            dsn = "sqlite:///" + path.as_posix().lstrip("/")
            db = preflight.ReadOnlyDB(dsn, "public")
            try:
                metrics, skipped = preflight._run_metrics(db)
                self.assertEqual(metrics["total_users"], 3)
                self.assertEqual(metrics["email_lower_duplicate_groups"], 1)
                self.assertEqual(metrics["only_student_id"], 1)
                self.assertEqual(skipped, [])
                with self.assertRaises(sqlite3.OperationalError):
                    db.conn.execute("CREATE TABLE should_not_exist (id INTEGER)")
            finally:
                db.close()

    def test_sqlite_uri_rejects_writable_and_memory_modes(self) -> None:
        with self.assertRaises(ValueError):
            preflight._sqlite_read_only_uri("sqlite://file:sample.db?mode=rw")
        with self.assertRaises(ValueError):
            preflight._sqlite_read_only_uri("sqlite://file::memory:?cache=shared")

    def test_missing_columns_propagate_unavailable_without_fake_categories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "incomplete-schema.db"
            connection = sqlite3.connect(path)
            connection.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
            connection.executemany(
                "INSERT INTO users (id, email) VALUES (?, ?)",
                [(1, "known@example.com"), (2, "")],
            )
            connection.commit()
            connection.close()

            db = preflight.ReadOnlyDB("sqlite://" + path.as_posix(), "public")
            try:
                metrics, skipped = preflight._run_metrics(db)
            finally:
                db.close()

            self.assertIsNone(metrics["email_unverified"])
            self.assertIsNone(metrics["qq_compatibility_email"])
            self.assertIn("email_unverified", skipped)
            report = preflight.build_report(metrics, skipped)
            category_a = report["categories"]["A_verified_real_email"]
            self.assertIsNone(category_a["count"])
            self.assertEqual(category_a["status"], "skipped_missing_metrics")
            self.assertEqual(category_a["auto_migrate"], False)
            self.assertCountEqual(
                category_a["missing_metrics"],
                ["email_unverified", "qq_compatibility_email"],
            )
            self.assertEqual(report["categories"]["D_no_email"]["count"], 1)
            serialized = json.dumps(report, ensure_ascii=False)
            self.assertIn('"count": null', serialized)
            self.assertNotEqual(category_a["count"], 2)

    def test_report_and_markdown_do_not_contain_raw_identifiers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self._database(Path(directory))
            dsn = "sqlite://" + path.as_posix()
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = preflight.main(["--dsn", dsn, "--format", "json"])
            self.assertEqual(code, 0)
            report = json.loads(output.getvalue())
            self.assertEqual(report["metrics"]["total_users"], 3)
            serialized = output.getvalue()
            self.assertNotIn("Alice@Example.com", serialized)
            self.assertNotIn("2026000001", serialized)
            self.assertIn("script_sha256", serialized)


if __name__ == "__main__":
    unittest.main()
