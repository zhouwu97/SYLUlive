from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SERVICE_ROOT = ROOT / "python-rag-service"
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

from app.agent_quality import (  # noqa: E402
    CASE_SCHEMA_VERSION,
    MANIFEST_SCHEMA_VERSION,
    AgentQualityError,
    load_quality_dataset,
    run_quality_gate,
)


FIXTURE_MANIFEST = ROOT / "server" / "testdata" / "ai_eval" / "agent_quality_manifest.json"


def test_calibration_and_holdout_are_disjoint_and_gate_passes():
    dataset = load_quality_dataset(FIXTURE_MANIFEST)
    calibration_ids = {case["id"] for case in dataset.calibration}
    holdout_ids = {case["id"] for case in dataset.holdout}
    assert calibration_ids.isdisjoint(holdout_ids)
    report = run_quality_gate(dataset)
    assert report["blocked"] is False
    assert report["publish_decision"] == "eligible_for_review"
    assert report["requests_performed"] == 0
    assert report["writes_performed"] is False
    assert all(value == "pass" for value in report["gates"].values())


def test_duplicate_case_id_across_splits_is_rejected(tmp_path):
    manifest = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    calibration = FIXTURE_MANIFEST.parent / "calibration" / "cases.jsonl"
    holdout = FIXTURE_MANIFEST.parent / "holdout" / "cases.jsonl"
    calibration_copy = tmp_path / "calibration.jsonl"
    holdout_copy = tmp_path / "holdout.jsonl"
    first = calibration.read_text(encoding="utf-8").splitlines()[0]
    second = holdout.read_text(encoding="utf-8").splitlines()[0]
    calibration_copy.write_text(first + "\n", encoding="utf-8")
    duplicate = json.loads(second)
    duplicate["id"] = json.loads(first)["id"]
    holdout_copy.write_text(json.dumps(duplicate, ensure_ascii=False) + "\n", encoding="utf-8")
    manifest["calibration"] = {"path": "calibration.jsonl"}
    manifest["holdout"] = {"path": "holdout.jsonl"}
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    with pytest.raises(AgentQualityError, match="重复 case ID"):
        load_quality_dataset(manifest_path)


def test_cross_split_reference_is_rejected(tmp_path):
    manifest = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    calibration = FIXTURE_MANIFEST.parent / "calibration" / "cases.jsonl"
    holdout = FIXTURE_MANIFEST.parent / "holdout" / "cases.jsonl"
    calibration_cases = [json.loads(line) for line in calibration.read_text(encoding="utf-8").splitlines() if line]
    holdout_cases = [json.loads(line) for line in holdout.read_text(encoding="utf-8").splitlines() if line]
    calibration_cases[0]["related_case_ids"] = [holdout_cases[0]["id"]]
    (tmp_path / "calibration.jsonl").write_text(
        "\n".join(json.dumps(value, ensure_ascii=False) for value in calibration_cases) + "\n", encoding="utf-8"
    )
    (tmp_path / "holdout.jsonl").write_text(
        "\n".join(json.dumps(value, ensure_ascii=False) for value in holdout_cases) + "\n", encoding="utf-8"
    )
    manifest["calibration"] = {"path": "calibration.jsonl"}
    manifest["holdout"] = {"path": "holdout.jsonl"}
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    with pytest.raises(AgentQualityError, match="跨 calibration/holdout"):
        load_quality_dataset(manifest_path)


def test_sensitive_question_or_answer_fields_are_rejected(tmp_path):
    manifest = json.loads(FIXTURE_MANIFEST.read_text(encoding="utf-8"))
    calibration = FIXTURE_MANIFEST.parent / "calibration" / "cases.jsonl"
    holdout = FIXTURE_MANIFEST.parent / "holdout" / "cases.jsonl"
    calibration_copy = tmp_path / "calibration.jsonl"
    holdout_copy = tmp_path / "holdout.jsonl"
    case = json.loads(calibration.read_text(encoding="utf-8").splitlines()[0])
    case["question_hash"] = "should-not-be-accepted-as-question-field"
    calibration_copy.write_text(json.dumps(case, ensure_ascii=False) + "\n", encoding="utf-8")
    holdout_copy.write_text(holdout.read_text(encoding="utf-8"), encoding="utf-8")
    manifest["calibration"] = {"path": "calibration.jsonl"}
    manifest["holdout"] = {"path": "holdout.jsonl"}
    manifest["calibration"]["case_ids"] = [case["id"]]
    manifest["holdout"]["case_ids"] = [json.loads(line)["id"] for line in holdout.read_text(encoding="utf-8").splitlines() if line]
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    with pytest.raises(AgentQualityError, match="禁止字段"):
        load_quality_dataset(manifest_path)


def test_schema_constants_are_versioned():
    assert MANIFEST_SCHEMA_VERSION.endswith("/v1")
    assert CASE_SCHEMA_VERSION.endswith("/v1")
