from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import collect_ai_baseline as baseline


class CollectAiBaselineTests(unittest.TestCase):
    def test_env_parser_only_keeps_allowlisted_flags(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text(
                "AI_POLICY_RAG_ENABLED=true\n"
                "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT=20\n"
                "OPENAI_API_KEY=should-not-leak\n",
                encoding="utf-8",
            )
            values = baseline.parse_env_file(path)
        self.assertEqual(values["AI_POLICY_RAG_ENABLED"], True)
        self.assertEqual(values["AI_LANGCHAIN_RAG_ROLLOUT_PERCENT"], 20)
        self.assertNotIn("OPENAI_API_KEY", values)

    def test_timing_contract_rejects_raw_question_and_bad_hmac(self) -> None:
        valid = {
            "case_id": "c001",
            "q_hmac": "0123456789abcdef01234567",
            "t_accept_ms": 1,
            "t_first_status_ms": 2,
            "t_first_delta_ms": 3,
            "t_complete_ms": 4,
            "tool_hit": False,
            "cancelled": False,
            "degraded": None,
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "timings.jsonl"
            path.write_text(json.dumps(valid) + "\n", encoding="utf-8")
            self.assertEqual(baseline.parse_timings(path)[0]["case_id"], "c001")
            invalid = dict(valid)
            invalid["question"] = "原问题文本"
            path.write_text(json.dumps(invalid) + "\n", encoding="utf-8")
            with self.assertRaises(baseline.BaselineError):
                baseline.parse_timings(path)

            invalid = dict(valid)
            invalid["q_hmac"] = "not-a-hmac"
            path.write_text(json.dumps(invalid) + "\n", encoding="utf-8")
            with self.assertRaises(baseline.BaselineError):
                baseline.parse_timings(path)

            invalid["q_hmac"] = valid["q_hmac"]
            invalid["t_first_status_ms"] = 0
            invalid["t_accept_ms"] = 1
            path.write_text(json.dumps(invalid) + "\n", encoding="utf-8")
            with self.assertRaises(baseline.BaselineError):
                baseline.parse_timings(path)

            path.write_text(
                json.dumps(valid) + "\n" + json.dumps(valid) + "\n", encoding="utf-8"
            )
            with self.assertRaises(baseline.BaselineError):
                baseline.parse_timings(path)

    def test_sensitive_key_scan_is_recursive(self) -> None:
        with self.assertRaises(baseline.BaselineError):
            baseline._assert_no_sensitive_data({"nested": {"answer": "正文"}})

    def test_file_metadata_hashes_without_copying_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "binary"
            payload = b"fixture-binary"
            path.write_bytes(payload)
            metadata = baseline.collect_file_metadata(path)
        self.assertEqual(metadata["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(metadata["size_bytes"], len(payload))
        self.assertNotIn("payload", metadata)

    def test_dry_run_does_not_write_requested_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "baseline.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "collect_ai_baseline.py"),
                    "--repo",
                    str(SCRIPT_DIR.parent),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(output.exists())
            self.assertIn('"writes_performed": false', result.stdout)

    def test_execute_requires_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "baseline.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "collect_ai_baseline.py"),
                    "--repo",
                    str(SCRIPT_DIR.parent),
                    "--output",
                    str(output),
                    "--execute",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"},
            )
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())
            self.assertIn("确认短语", result.stderr)

    def test_markdown_render_is_fixed_field_only(self) -> None:
        bundle = {
            "schema_version": baseline.SCHEMA_VERSION,
            "generated_at": "2026-09-02T00:00:00+00:00",
            "evidence_type": "fixture",
            "collection_mode": "local_read_only_inputs",
            "repository": {"branch": "ai-test", "commit": "a" * 40},
            "deployment": {
                "binaries": [],
                "flags": {"code_defaults": {}, "runtime_values": {}},
                "systemd": [],
                "mcp": None,
                "knowledge": None,
            },
            "timings": [],
            "missing": ["timings"],
        }
        report = baseline.render_markdown(bundle)
        self.assertIn("# 优化基线报告（T00）", report)
        self.assertIn("待补：timings", report)
        self.assertNotIn("敏感答案示例", report)

    def test_execute_writes_sanitized_json_and_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "service.bin"
            binary.write_bytes(b"safe-fixture")
            env = root / ".env"
            env.write_text(
                "AI_POLICY_RAG_ENABLED=false\n"
                "AI_LANGCHAIN_RAG_ENABLED=false\n"
                "AI_LEGACY_RAG_ENABLED=true\n"
                "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT=0\n"
                "AI_AGENT_ENABLED=false\n"
                "RAG_RERANKER_ENABLED=false\n"
                "RAG_RETRIEVER_ENABLED=true\n"
                "RAG_GENERATION_ENABLED=true\n"
                "RAG_SHADOW_INDEX_ENABLED=true\n"
                "RAG_ALLOW_LANGSMITH=false\n"
                "RAG_SERVICE_TOKEN=must-not-appear\n",
                encoding="utf-8",
            )
            mcp = root / "mcp.json"
            mcp.write_text(
                json.dumps(
                    {
                        "enabled": False,
                        "protocol": "stdio",
                        "healthy": True,
                        "token": "drop",
                    }
                ),
                encoding="utf-8",
            )
            knowledge = root / "knowledge.json"
            knowledge.write_text(
                json.dumps(
                    {
                        "version": "v0.8",
                        "schema_version": "manifest/v1",
                        "embedding_model": "fixture-model",
                        "embedding_dimension": 384,
                        "sha256": "a" * 64,
                        "status": "published",
                        "answer": "drop",
                    }
                ),
                encoding="utf-8",
            )
            timings = root / "timings.jsonl"
            timings.write_text(
                json.dumps(
                    {
                        "case_id": "c001",
                        "q_hmac": "0123456789abcdef01234567",
                        "t_accept_ms": 1,
                        "t_first_status_ms": 2,
                        "t_first_delta_ms": 3,
                        "t_complete_ms": 4,
                        "tool_hit": False,
                        "cancelled": False,
                        "degraded": None,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            output = root / "baseline.json"
            markdown = root / "baseline.md"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "collect_ai_baseline.py"),
                    "--evidence-type",
                    "fixture",
                    "--repo",
                    str(SCRIPT_DIR.parent),
                    "--binary",
                    str(binary),
                    "--runtime-env",
                    str(env),
                    "--defaults-env",
                    str(env),
                    "--mcp-status",
                    str(mcp),
                    "--knowledge-manifest",
                    str(knowledge),
                    "--timings-jsonl",
                    str(timings),
                    "--output",
                    str(output),
                    "--markdown-output",
                    str(markdown),
                    "--execute",
                    "--confirm",
                    "WRITE:T00-BASELINE",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"},
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(payload["writes_performed"])
            self.assertEqual(payload["deployment"]["mcp"]["protocol"], "stdio")
            serialized = output.read_text(encoding="utf-8")
            self.assertNotIn("must-not-appear", serialized)
            self.assertNotIn('"answer"', serialized)
            self.assertTrue(markdown.exists())

    def test_online_write_requires_online_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "baseline.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "collect_ai_baseline.py"),
                    "--evidence-type",
                    "online",
                    "--repo",
                    str(SCRIPT_DIR.parent),
                    "--output",
                    str(output),
                    "--execute",
                    "--confirm",
                    "WRITE:T00-BASELINE",
                ],
                check=False,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"},
            )
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())
            self.assertIn("WRITE:T00-ONLINE-READONLY", result.stderr)


if __name__ == "__main__":
    unittest.main()
