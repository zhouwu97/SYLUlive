"""identity_dependency_inventory 的无外部依赖单元测试。"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

# 目录不是 Python package 时，测试仍可从仓库根目录直接运行。
sys.path.insert(0, str(Path(__file__).resolve().parent))
import identity_dependency_inventory as inventory


class IdentityDependencyInventoryTest(unittest.TestCase):
    def test_aggregate_has_categories_without_source_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "server" / "internal" / "handlers").mkdir(parents=True)
            (root / "server" / "internal" / "handlers" / "admin.go").write_text(
                'query := "SELECT student_id, email FROM users"\n'
                'return map[string]string{"email": "alice@example.com"}\n'
                'user.StudentID = "2026000001"\n',
                encoding="utf-8",
            )
            (root / "server" / "internal" / "handlers" / "admin_test.go").write_text(
                'fixture := map[string]string{"student_id": "2026000001"}\n',
                encoding="utf-8",
            )

            report = inventory.build_inventory(root)
            rows = report["rows"]
            self.assertTrue(any(row["category"] == "read" for row in rows))
            self.assertTrue(any(row["category"] == "response_output" for row in rows))
            self.assertTrue(any(row["category"] == "test_fixture" for row in rows))
            serialized = json.dumps(report, ensure_ascii=False)
            self.assertNotIn("alice@example.com", serialized)
            self.assertNotIn("2026000001", serialized)

    def test_dry_run_does_not_read_source(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = inventory.main(["--root", "C:/path/that/does/not/exist", "--dry-run"])
        self.assertEqual(code, 0)
        payload = json.loads(output.getvalue())
        self.assertTrue(payload["read_only"])
        self.assertIn("users.student_id", payload["dependencies"])


if __name__ == "__main__":
    unittest.main()
