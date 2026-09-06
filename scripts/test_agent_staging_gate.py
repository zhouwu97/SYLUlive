from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SERVICE_ROOT = ROOT / "python-rag-service"
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

from app.agent_staging_gate import (  # noqa: E402
    AgentStagingGateError,
    REQUIRED_FAILURE_CLASSES,
    evaluate_staging_gate,
    load_and_evaluate,
)


FIXTURE = ROOT / "server" / "testdata" / "ai_eval" / "agent_staging" / "staging_gate.fixture.json"


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def test_fixture_covers_all_failure_classes_and_is_dry_run():
    report = load_and_evaluate(FIXTURE)
    assert report["blocked"] is False
    assert report["mode"] == "dry_run"
    assert set(report["failure_classes"]) == set(REQUIRED_FAILURE_CLASSES)
    assert report["requests_performed"] == 0
    assert report["deployment_mutations"] == 0
    assert report["writes_performed"] is False
    assert all(value == "pass" for value in report["gates"].values())


def test_failed_fault_recovery_blocks_gate():
    fixture = _fixture()
    fixture["fault_injection"][0]["recovered"] = False
    report = evaluate_staging_gate(fixture)
    assert report["blocked"] is True
    assert report["gates"]["fault_injection"] == "fail"
    assert report["decision"] == "blocked"


def test_side_effects_block_dry_run():
    fixture = _fixture()
    fixture["side_effects"]["requests_performed"] = 1
    report = evaluate_staging_gate(fixture)
    assert report["blocked"] is True
    assert report["gates"]["side_effects"] == "fail"


def test_rollback_must_use_entry_snapshot_and_change_state():
    fixture = _fixture()
    fixture["rollback"]["before"]["code_version"] = "other-version"
    with pytest.raises(AgentStagingGateError, match="rollback.before"):
        evaluate_staging_gate(fixture)


def test_sensitive_fields_are_rejected():
    fixture = _fixture()
    fixture["fault_injection"][0]["request_token"] = "must-not-appear"
    with pytest.raises(AgentStagingGateError, match="禁止字段"):
        evaluate_staging_gate(fixture)


def test_report_does_not_contain_fixture_payload_or_unknown_fields():
    report = load_and_evaluate(FIXTURE)
    encoded = json.dumps(report, ensure_ascii=False)
    assert "fault-provider-timeout" in encoded
    assert "fixture-agent-code-v1" in encoded
    assert "request_token" not in encoded
