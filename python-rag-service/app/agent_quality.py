"""校园 Agent A3 结构化质量评测与知识版本门禁。

评测数据只保存类型化查询键、来源元数据、引用定位和结论 ID，不保存问题正文、
答案正文或个人字段。模块不访问网络、不连接数据库，staging/线上采集器可以把
脱敏后的观测转换为同一契约后复用这里的校验。
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping


MANIFEST_SCHEMA_VERSION = "campus-agent-quality-split/v1"
CASE_SCHEMA_VERSION = "campus-agent-quality-case/v1"
QUALITY_REPORT_SCHEMA_VERSION = "campus-agent-quality-gate/v1"

DEFAULT_MINIMUMS: dict[str, float] = {
    "citation_validity": 1.0,
    "freshness_safety": 1.0,
    "key_conclusion_consistency": 1.0,
    "refusal_accuracy": 1.0,
    "historical_boundary": 1.0,
}

_FORBIDDEN_FIELD_PARTS = {
    "answer",
    "cookie",
    "credential",
    "dsn",
    "jwt",
    "password",
    "prompt",
    "question",
    "secret",
    "student",
    "token",
}

_ALLOWED_FRESHNESS = {"fresh", "stale", "expired", "unknown"}
_ALLOWED_SOURCE_STATUS = {"published", "superseded", "revoked", "draft"}
_ALLOWED_INPUT_FORMS = {"canonical", "alias", "colloquial", "typo", "compound"}


class AgentQualityError(ValueError):
    """评测清单、分片或观测不满足契约。"""


@dataclass(frozen=True)
class QualityDataset:
    """互斥的校准集和留出集。"""

    manifest_path: Path
    manifest: dict[str, Any]
    calibration: tuple[dict[str, Any], ...]
    holdout: tuple[dict[str, Any], ...]


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AgentQualityError(f"无法读取 JSON 清单：{path}: {exc}") from exc
    if not isinstance(value, dict):
        raise AgentQualityError(f"JSON 根节点必须是对象：{path}")
    return value


def _reject_sensitive_fields(value: Any, path: str = "$") -> None:
    """拒绝容易把敏感原文带入评测夹具的字段名。"""

    if isinstance(value, Mapping):
        for key, child in value.items():
            normalized = str(key).casefold().replace("-", "_")
            parts = {part for part in normalized.split("_") if part}
            if parts & _FORBIDDEN_FIELD_PARTS:
                raise AgentQualityError(f"评测数据包含禁止字段：{path}.{key}")
            _reject_sensitive_fields(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_sensitive_fields(child, f"{path}[{index}]")


def _require_string(value: Any, field: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise AgentQualityError(f"字段 {field} 必须是非空字符串")
    return value.strip()


def _require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise AgentQualityError(f"字段 {field} 必须是数组")
    return value


def _normalize_split_entry(manifest: Mapping[str, Any], name: str) -> tuple[str, list[str] | None]:
    raw = manifest.get(name)
    if isinstance(raw, str):
        return raw, None
    if not isinstance(raw, Mapping):
        raise AgentQualityError(f"manifest.{name} 必须是路径或对象")
    path = _require_string(raw.get("path"), f"manifest.{name}.path")
    case_ids = raw.get("case_ids")
    if case_ids is None:
        return path, None
    values = _require_list(case_ids, f"manifest.{name}.case_ids")
    normalized = [_require_string(item, f"manifest.{name}.case_ids[]") for item in values]
    if len(normalized) != len(set(normalized)):
        raise AgentQualityError(f"manifest.{name}.case_ids 存在重复")
    return path, normalized


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise AgentQualityError(f"无法读取评测分片：{path}: {exc}") from exc
    cases: list[dict[str, Any]] = []
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise AgentQualityError(f"{path}:{line_number} 不是有效 JSON：{exc}") from exc
        if not isinstance(value, dict):
            raise AgentQualityError(f"{path}:{line_number} 根节点必须是对象")
        cases.append(value)
    if not cases:
        raise AgentQualityError(f"评测分片不能为空：{path}")
    return cases


def _validate_case_shape(case: Mapping[str, Any], *, source: str) -> str:
    _reject_sensitive_fields(case)
    if case.get("schema_version") != CASE_SCHEMA_VERSION:
        raise AgentQualityError(f"{source} 的 schema_version 不匹配")
    case_id = _require_string(case.get("id"), f"{source}.id")
    category = _require_string(case.get("category"), f"{source}.category")
    input_form = _require_string(case.get("input_form", "canonical"), f"{source}.input_form")
    if input_form not in _ALLOWED_INPUT_FORMS:
        raise AgentQualityError(f"{source}.input_form 不受支持：{input_form}")
    _require_string(case.get("query_key"), f"{source}.query_key")
    expected = case.get("expected")
    if not isinstance(expected, Mapping):
        raise AgentQualityError(f"{source}.expected 必须是对象")
    expected_sources = _require_list(expected.get("source_ids", []), f"{source}.expected.source_ids")
    if any(not isinstance(item, str) or not item.strip() for item in expected_sources):
        raise AgentQualityError(f"{source}.expected.source_ids 含非法值")
    conclusions = _require_list(expected.get("conclusions", []), f"{source}.expected.conclusions")
    if any(not isinstance(item, str) or not item.strip() for item in conclusions):
        raise AgentQualityError(f"{source}.expected.conclusions 含非法值")
    if not isinstance(expected.get("should_refuse"), bool):
        raise AgentQualityError(f"{source}.expected.should_refuse 必须是布尔值")
    sources = _require_list(case.get("sources", []), f"{source}.sources")
    if not sources:
        raise AgentQualityError(f"{source}.sources 不能为空")
    observations = case.get("observation")
    if not isinstance(observations, Mapping):
        raise AgentQualityError(f"{source}.observation 必须是对象")
    if not isinstance(observations.get("refused"), bool):
        raise AgentQualityError(f"{source}.observation.refused 必须是布尔值")
    observed_conclusions = _require_list(
        observations.get("conclusions", []), f"{source}.observation.conclusions"
    )
    if any(not isinstance(item, str) or not item.strip() for item in observed_conclusions):
        raise AgentQualityError(f"{source}.observation.conclusions 含非法值")
    citations = _require_list(observations.get("citations", []), f"{source}.observation.citations")
    for citation in citations:
        if not isinstance(citation, Mapping):
            raise AgentQualityError(f"{source}.observation.citations 含非法项")
        _require_string(citation.get("source_id"), f"{source}.observation.citations[].source_id")
        _require_string(citation.get("locator"), f"{source}.observation.citations[].locator")
        if not isinstance(citation.get("valid"), bool):
            raise AgentQualityError(f"{source}.observation.citations[].valid 必须是布尔值")
    return case_id


def _validate_manifest_case_ids(
    manifest: Mapping[str, Any], name: str, cases: list[dict[str, Any]], declared: list[str] | None
) -> None:
    actual = [str(case["id"]) for case in cases]
    if len(actual) != len(set(actual)):
        raise AgentQualityError(f"{name} 分片存在重复 case ID")
    if declared is not None and actual != declared:
        raise AgentQualityError(f"manifest.{name}.case_ids 与分片内容不一致")


def load_quality_dataset(manifest_path: Path) -> QualityDataset:
    """读取并严格校验互斥的 calibration/holdout 分片。"""

    manifest_path = manifest_path.resolve()
    manifest = _read_json(manifest_path)
    _reject_sensitive_fields(manifest)
    if manifest.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        raise AgentQualityError("评测 split manifest schema_version 不匹配")
    _require_string(manifest.get("knowledge_version"), "manifest.knowledge_version")
    calibration_ref, calibration_ids = _normalize_split_entry(manifest, "calibration")
    holdout_ref, holdout_ids = _normalize_split_entry(manifest, "holdout")
    calibration_path = (manifest_path.parent / calibration_ref).resolve()
    holdout_path = (manifest_path.parent / holdout_ref).resolve()
    if calibration_path == holdout_path:
        raise AgentQualityError("calibration 与 holdout 不得引用同一文件")
    try:
        calibration_path.relative_to(manifest_path.parent)
        holdout_path.relative_to(manifest_path.parent)
    except ValueError as exc:
        raise AgentQualityError("评测分片路径必须位于 manifest 目录内") from exc
    calibration = _load_jsonl(calibration_path)
    holdout = _load_jsonl(holdout_path)
    for name, path, cases, declared in (
        ("calibration", calibration_path, calibration, calibration_ids),
        ("holdout", holdout_path, holdout, holdout_ids),
    ):
        for line_number, case in enumerate(cases, start=1):
            _validate_case_shape(case, source=f"{path}:{line_number}")
        _validate_manifest_case_ids(manifest, name, cases, declared)
    calibration_case_ids = {str(case["id"]) for case in calibration}
    holdout_case_ids = {str(case["id"]) for case in holdout}
    overlap = calibration_case_ids & holdout_case_ids
    if overlap:
        raise AgentQualityError(f"calibration/holdout 存在重复 case ID：{sorted(overlap)}")
    all_case_ids = calibration_case_ids | holdout_case_ids
    for split_name, cases in (("calibration", calibration), ("holdout", holdout)):
        for case in cases:
            for field in ("related_case_ids", "depends_on"):
                references = case.get(field, [])
                if references is None:
                    continue
                if not isinstance(references, list) or any(not isinstance(item, str) for item in references):
                    raise AgentQualityError(f"{split_name}/{case['id']}.{field} 格式非法")
                foreign = [item for item in references if item not in all_case_ids]
                if foreign:
                    raise AgentQualityError(
                        f"{split_name}/{case['id']}.{field} 引用了不存在的 case：{sorted(foreign)}"
                    )
                cross = [
                    item
                    for item in references
                    if (item in calibration_case_ids) != (split_name == "calibration")
                ]
                if cross:
                    raise AgentQualityError(
                        f"{split_name}/{case['id']}.{field} 不能跨 calibration/holdout 交叉引用：{sorted(cross)}"
                    )
    return QualityDataset(
        manifest_path=manifest_path,
        manifest=manifest,
        calibration=tuple(calibration),
        holdout=tuple(holdout),
    )


def _source_map(case: Mapping[str, Any]) -> tuple[dict[str, Mapping[str, Any]], list[str]]:
    sources = case.get("sources", [])
    by_id: dict[str, Mapping[str, Any]] = {}
    failures: list[str] = []
    for source in sources:
        if not isinstance(source, Mapping):
            failures.append("source_shape")
            continue
        source_id = str(source.get("source_id", "")).strip()
        if not source_id or source_id in by_id:
            failures.append("duplicate_or_missing_source")
            continue
        by_id[source_id] = source
        status = str(source.get("status", "")).strip()
        freshness = str(source.get("freshness", "")).strip()
        locator = str(source.get("locator", "")).strip()
        if status not in _ALLOWED_SOURCE_STATUS:
            failures.append(f"source_status:{source_id}")
        if freshness not in _ALLOWED_FRESHNESS:
            failures.append(f"source_freshness:{source_id}")
        if not locator:
            failures.append(f"source_locator:{source_id}")
        if source.get("historical") not in (True, False):
            failures.append(f"source_historical:{source_id}")
    return by_id, failures


def _evaluate_case(case: Mapping[str, Any], knowledge_version: str) -> tuple[dict[str, Any], list[str]]:
    case_id = str(case["id"])
    expected = case["expected"]
    observation = case["observation"]
    sources, failures = _source_map(case)
    expected_source_ids = {str(item) for item in expected.get("source_ids", [])}
    missing_sources = sorted(expected_source_ids - set(sources))
    if missing_sources:
        failures.append("expected_source_missing")
    for source_id, source in sources.items():
        if str(source.get("knowledge_version", "")).strip() != knowledge_version:
            failures.append(f"knowledge_version:{source_id}")

    citations = observation.get("citations", [])
    cited_ids: set[str] = set()
    invalid_citation = False
    for citation in citations:
        source_id = str(citation.get("source_id", "")).strip()
        cited_ids.add(source_id)
        source = sources.get(source_id)
        valid = citation.get("valid") is True
        if source is None or not valid:
            invalid_citation = True
            continue
        if str(citation.get("locator", "")).strip() != str(source.get("locator", "")).strip():
            invalid_citation = True
        if source.get("status") != "published":
            invalid_citation = True
        if source.get("freshness") in {"stale", "expired", "unknown"}:
            invalid_citation = True
    expected_refusal = bool(expected.get("should_refuse"))
    observed_refusal = bool(observation.get("refused"))
    refusal_ok = observed_refusal == expected_refusal
    if not refusal_ok:
        failures.append("refusal_mismatch")

    stale_sources = [
        source_id
        for source_id, source in sources.items()
        if source.get("freshness") in {"stale", "expired", "unknown"}
    ]
    freshness_safe = not stale_sources or observed_refusal
    if not freshness_safe:
        failures.append("stale_source_used_as_fact")

    observed_conclusions = {str(item) for item in observation.get("conclusions", [])}
    required_conclusions = {str(item) for item in expected.get("conclusions", [])}
    forbidden_conclusions = {str(item) for item in expected.get("forbidden_conclusions", [])}
    conclusion_ok = required_conclusions.issubset(observed_conclusions) and not (
        forbidden_conclusions & observed_conclusions
    )
    if not conclusion_ok:
        failures.append("key_conclusion_mismatch")

    source_coverage_ok = expected_refusal or expected_source_ids.issubset(cited_ids)
    if not source_coverage_ok:
        failures.append("expected_source_not_cited")

    mixed_history = any(bool(source.get("historical")) for source in sources.values()) and any(
        not bool(source.get("historical")) for source in sources.values()
    )
    boundary_ack = bool(observation.get("historical_boundary_acknowledged", False))
    history_ok = not mixed_history or boundary_ack
    if not history_ok:
        failures.append("historical_current_boundary_missing")

    conflict_sources = expected.get("conflicting_source_ids", [])
    conflict_present = bool(conflict_sources) or bool(expected.get("conflict_policy"))
    conflict_ok = not conflict_present or expected_refusal or boundary_ack
    if not conflict_ok:
        failures.append("source_conflict_not_handled")

    # 无效引用只有在可靠拒答时才是安全结果；正常回答必须全部引用合法。
    citation_ok = (not invalid_citation) or observed_refusal
    if not citation_ok:
        failures.append("invalid_citation_accepted")

    return (
        {
            "case_id": case_id,
            "category": str(case.get("category", "")),
            "input_form": str(case.get("input_form", "canonical")),
            "passed": not failures,
            "citation_safe": citation_ok,
            "freshness_safe": freshness_safe,
            "conclusion_consistent": conclusion_ok,
            "refusal_correct": refusal_ok,
            "historical_boundary_safe": history_ok,
            "source_coverage": source_coverage_ok,
            "invalid_citation_detected": invalid_citation,
            "stale_source_detected": bool(stale_sources),
            "failures": sorted(set(failures)),
        },
        sorted(set(failures)),
    )


def _rate(results: Iterable[Mapping[str, Any]], field: str) -> float:
    values = list(results)
    if not values:
        return 1.0
    return round(sum(bool(item.get(field)) for item in values) / len(values), 6)


def evaluate_quality_split(
    cases: Iterable[Mapping[str, Any]], *, knowledge_version: str, split: str
) -> dict[str, Any]:
    """评估一个分片，返回不含原文的类型化报告。"""

    normalized_version = _require_string(knowledge_version, "knowledge_version")
    if split not in {"calibration", "holdout"}:
        raise AgentQualityError(f"未知评测分片：{split}")
    results: list[dict[str, Any]] = []
    for case in cases:
        _validate_case_shape(case, source=f"{split}/{case.get('id', 'unknown')}")
        result, _ = _evaluate_case(case, normalized_version)
        results.append(result)
    metrics = {
        "citation_validity": _rate(results, "citation_safe"),
        "freshness_safety": _rate(results, "freshness_safe"),
        "key_conclusion_consistency": _rate(results, "conclusion_consistent"),
        "refusal_accuracy": _rate(results, "refusal_correct"),
        "historical_boundary": _rate(results, "historical_boundary_safe"),
        "source_coverage": _rate(results, "source_coverage"),
    }
    return {
        "split": split,
        "cases": len(results),
        "passed_cases": sum(bool(item["passed"]) for item in results),
        "metrics": metrics,
        "failures": [item for item in results if not item["passed"]],
    }


def run_quality_gate(dataset: QualityDataset) -> dict[str, Any]:
    """执行独立 A3 门禁；任一分片或关键质量指标失败即 blocked。"""

    knowledge_version = _require_string(dataset.manifest.get("knowledge_version"), "knowledge_version")
    calibration = evaluate_quality_split(
        dataset.calibration, knowledge_version=knowledge_version, split="calibration"
    )
    holdout = evaluate_quality_split(
        dataset.holdout, knowledge_version=knowledge_version, split="holdout"
    )
    configured = dataset.manifest.get("minimums", {})
    if not isinstance(configured, Mapping):
        raise AgentQualityError("manifest.minimums 必须是对象")
    minimums = dict(DEFAULT_MINIMUMS)
    for key, value in configured.items():
        if key not in minimums or not isinstance(value, (int, float)) or not 0 <= float(value) <= 1:
            raise AgentQualityError(f"manifest.minimums.{key} 非法")
        minimums[key] = float(value)

    gates: dict[str, str] = {}
    blocking_reasons: list[dict[str, Any]] = []
    for split_report in (calibration, holdout):
        split_name = split_report["split"]
        if split_report["passed_cases"] != split_report["cases"]:
            gates[f"{split_name}_cases"] = "fail"
            blocking_reasons.append(
                {"gate": f"{split_name}_cases", "reason": "存在未通过的结构化用例"}
            )
        else:
            gates[f"{split_name}_cases"] = "pass"
        for metric, minimum in minimums.items():
            actual = float(split_report["metrics"].get(metric, 0.0))
            gate_name = f"{split_name}_{metric}"
            if actual < minimum:
                gates[gate_name] = "fail"
                blocking_reasons.append(
                    {
                        "gate": gate_name,
                        "reason": "指标低于门槛",
                        "actual": actual,
                        "minimum": minimum,
                    }
                )
            else:
                gates[gate_name] = "pass"
    blocked = bool(blocking_reasons)
    return {
        "schema_version": QUALITY_REPORT_SCHEMA_VERSION,
        "evidence_type": str(dataset.manifest.get("evidence_type", "fixture")),
        "knowledge_version": knowledge_version,
        "manifest": dataset.manifest_path.name,
        "calibration": calibration,
        "holdout": holdout,
        "minimums": minimums,
        "gates": gates,
        "blocked": blocked,
        "blocking_reasons": blocking_reasons,
        "publish_decision": "blocked" if blocked else "eligible_for_review",
        "rollout_decision": "blocked" if blocked else "eligible_for_review",
        "writes_performed": False,
        "requests_performed": 0,
    }


__all__ = [
    "CASE_SCHEMA_VERSION",
    "DEFAULT_MINIMUMS",
    "MANIFEST_SCHEMA_VERSION",
    "QUALITY_REPORT_SCHEMA_VERSION",
    "AgentQualityError",
    "QualityDataset",
    "evaluate_quality_split",
    "load_quality_dataset",
    "run_quality_gate",
]
