import json
from pathlib import Path

import pytest

from scripts.rollout_guard import (
    EVIDENCE_SCHEMA_VERSION,
    REQUIRED_GATES,
    RolloutGuardError,
    advance_state,
    environment_for_stage,
    load_state,
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
    assert environment_for_stage("internal")["AI_INTERNAL_TEST_ONLY"] == "true"
    assert environment_for_stage("5")["AI_LANGCHAIN_RAG_ROLLOUT_PERCENT"] == "5"
    assert environment_for_stage("100")["AI_LEGACY_RAG_ENABLED"] == "true"
    assert environment_for_stage("off")["AI_LANGCHAIN_RAG_ENABLED"] == "false"
