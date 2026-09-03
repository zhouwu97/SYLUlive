from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import collect_ai_baseline as baseline


class CollectAiBaselineTests(unittest.TestCase):
    def _event(self, case_id: str, seq: int, event: str, **overrides: Any) -> dict[str, Any]:
        value: dict[str, Any] = {
            "schema_version": baseline.EVENT_SCHEMA_VERSION,
            "case_id": case_id,
            "q_hmac": "0123456789abcdef01234567",
            "seq": seq,
            "event": event,
            "elapsed_ms": seq,
            "capability": None,
            "provider_ms": None,
            "rag_ms": None,
            "tool_ms": None,
            "visible_tool_count": None,
            "schema_token_estimate": None,
            "grant_failures": 0,
            "knowledge_version": None,
            "degradation": None,
            "reconnect_attempt": None,
        }
        value.update(overrides)
        return value

    def test_event_contract_accepts_fixture_and_summarizes_closed_run(self) -> None:
        path = SCRIPT_DIR.parent / "server" / "testdata" / "ai_eval" / "campus_agent_events.fixture.jsonl"
        events = baseline.parse_events(path)
        self.assertEqual(len(events), 41)
        summary = baseline.summarize_events(events)
        self.assertIsNotNone(summary)
        assert summary is not None
        self.assertEqual(summary["case_count"], 8)
        self.assertEqual(
            summary["terminal_counts"],
            {"cancel.completed": 1, "run.completed": 7},
        )
        self.assertEqual(summary["first_delta_cases"], 8)
        self.assertEqual(summary["reconnected_cases"], 1)
        self.assertEqual(summary["tool_event_count"], 6)
        self.assertEqual(summary["knowledge_versions"], [
            "fixture-academic-v1",
            "fixture-calendar-v1",
            "fixture-canteen-v1",
            "fixture-competition-v1",
            "fixture-policy-v1",
            "fixture-runtime-v1",
            "fixture-schedule-v1",
        ])

    def test_event_contract_rejects_unclosed_or_out_of_order_runs(self) -> None:
        valid = [
            self._event("case-a", 1, "run.accepted"),
            self._event("case-a", 2, "tool.started", capability="policy.search"),
            self._event("case-a", 3, "run.completed"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            path.write_text("\n".join(json.dumps(item) for item in valid) + "\n", encoding="utf-8")
            with self.assertRaises(baseline.BaselineError):
                baseline.parse_events(path)

            out_of_order = [self._event("case-a", 1, "state.first"), self._event("case-a", 2, "run.completed")]
            path.write_text("\n".join(json.dumps(item) for item in out_of_order) + "\n", encoding="utf-8")
            with self.assertRaises(baseline.BaselineError):
                baseline.parse_events(path)

    def test_event_contract_rejects_unmatched_reconnect_and_cancel(self) -> None:
        cases = [
            [self._event("case-a", 1, "run.accepted"), self._event("case-a", 2, "run.reconnected", reconnect_attempt=1)],
            [self._event("case-a", 1, "run.accepted"), self._event("case-a", 2, "run.cancelled"), self._event("case-a", 3, "run.completed")],
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            for events in cases:
                path.write_text("\n".join(json.dumps(item) for item in events) + "\n", encoding="utf-8")
                with self.assertRaises(baseline.BaselineError):
                    baseline.parse_events(path)

    def test_scenario_manifest_requires_all_domains_and_personal_grants(self) -> None:
        path = SCRIPT_DIR.parent / "server" / "testdata" / "ai_eval" / "campus_agent_scenarios.json"
        manifest = baseline.parse_scenario_manifest(path)
        self.assertIsNotNone(manifest)
        assert manifest is not None
        self.assertEqual(len(manifest["scenarios"]), 8)
        self.assertEqual(
            {item["domain"] for item in manifest["scenarios"]},
            set(baseline.SCENARIO_DOMAINS),
        )
        self.assertEqual(
            sum(bool(item["requires_grant"]) for item in manifest["scenarios"]), 3
        )

    def test_preview_lists_agent_event_and_scenario_collection(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "collect_ai_baseline.py"), "--repo", str(SCRIPT_DIR.parent)],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        preview = json.loads(result.stdout)
        self.assertIn("versioned_agent_events_jsonl", preview["would_collect"])
        self.assertIn("campus_agent_scenario_manifest", preview["would_collect"])

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

    def test_schema_token_estimate_max_is_safe_metric(self) -> None:
        baseline._assert_no_sensitive_data({"schema_token_estimate_max": 128})

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
