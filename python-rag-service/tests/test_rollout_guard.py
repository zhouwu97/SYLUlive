import json
from pathlib import Path

import pytest

from scripts.rollout_guard import (
    AGENT_QUALITY_SCHEMA_VERSION,
    EVIDENCE_SCHEMA_VERSION,
    REQUIRED_GATES,
    RolloutGuardError,
    advance_state,
    environment_for_stage,
    load_state,
    validate_agent_quality_report,
    validate_transition,
)


def _evidence(
    path: Path, stage: str, *, failed_gate: str = "", sample_size: int | None = None
) -> Path:
    gates = {name: "pass" for name in REQUIRED_GATES}
    if failed_gate:
        gates[failed_gate] = "fail"
    path.write_text(
        json.dumps(
            {
                "schema_version": EVIDENCE_SCHEMA_VERSION,
                "stage": stage,
                "sample_size": (
                    sample_size
                    if sample_size is not None
                    else (0 if stage == "preflight" else 20)
                ),
                "gates": gates,
            }
        ),
        encoding="utf-8",
    )
    return path


def test_rollout_guard_requires_every_stage_and_never_skips_to_full(tmp_path):
    state = load_state(tmp_path / "missing.json")
    with pytest.raises(RolloutGuardError, match="must be internal"):
        validate_transition("off", "100")

    stages = ("internal", "5", "20", "50", "100")
    evidence_stage = "preflight"
    for target in stages:
        evidence = _evidence(tmp_path / f"{target}.json", evidence_stage)
        state = advance_state(state, target, evidence)
        assert state["current_stage"] == target
        evidence_stage = target

    assert [item["to"] for item in state["history"]] == list(stages)


def test_rollout_guard_blocks_failed_gate_and_preserves_state(tmp_path):
    evidence = _evidence(tmp_path / "failed.json", "preflight", failed_gate="security_regression")
    state = load_state(tmp_path / "missing.json")

    with pytest.raises(RolloutGuardError, match="security_regression"):
        advance_state(state, "internal", evidence)

    assert state["current_stage"] == "off"
    assert state["history"] == []


def test_rollout_guard_allows_emergency_rollback_with_failed_gate(tmp_path):
    evidence = _evidence(
        tmp_path / "outage.json",
        "internal",
        failed_gate="error_rate",
        sample_size=0,
    )
    state = {
        "schema_version": "t09-rollout-state/v1",
        "current_stage": "internal",
        "history": [],
    }

    updated = advance_state(state, "rollback", evidence)

    assert updated["current_stage"] == "off"
    assert updated["history"][0]["to"] == "off"


def test_rollout_environment_keeps_legacy_path_during_full_observation_window():
    assert environment_for_stage("internal")["AI_LANGCHAIN_RAG_ROLLOUT_PERCENT"] == "100"
    assert environment_for_stage("5")["AI_LANGCHAIN_RAG_ROLLOUT_PERCENT"] == "5"
    assert environment_for_stage("100")["AI_LEGACY_RAG_ENABLED"] == "true"
    assert environment_for_stage("off")["AI_LANGCHAIN_RAG_ENABLED"] == "false"


def _quality_report(*, evidence_type: str = "staging", blocked: bool = False) -> dict:
    return {
        "schema_version": AGENT_QUALITY_SCHEMA_VERSION,
        "evidence_type": evidence_type,
        "knowledge_version": "kb-v1",
        "blocked": blocked,
        "publish_decision": "blocked" if blocked else "eligible_for_review",
        "rollout_decision": "blocked" if blocked else "eligible_for_review",
        "gates": {"holdout_citation_validity": "fail" if blocked else "pass"},
    }


def test_agent_quality_report_blocks_failed_or_fixture_runtime_evidence():
    with pytest.raises(RolloutGuardError, match="not passed"):
        validate_agent_quality_report(_quality_report(blocked=True))
    with pytest.raises(RolloutGuardError, match="fixture"):
        validate_agent_quality_report(
            _quality_report(evidence_type="fixture"), require_runtime_evidence=True
        )
    validate_agent_quality_report(_quality_report())


def test_advance_state_records_agent_quality_digest_and_version(tmp_path):
    evidence = _evidence(tmp_path / "preflight.json", "preflight")
    quality_path = tmp_path / "quality.json"
    quality_path.write_text(json.dumps(_quality_report()), encoding="utf-8")
    state = load_state(tmp_path / "state.json")
    updated = advance_state(state, "internal", evidence, quality_path)
    assert updated["history"][0]["agent_quality_knowledge_version"] == "kb-v1"
    assert updated["history"][0]["agent_quality_sha256"]
