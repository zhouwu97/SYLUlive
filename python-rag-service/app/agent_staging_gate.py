"""校园 Agent A4 staging 场景门禁。

该模块只解析脱敏的故障注入记录和版本快照，不发起 HTTP/SSH 请求，不修改部署。
默认输出 dry-run 证据；只有真实授权的 staging 采集器才可把环境标记为 staging。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping


STAGING_FIXTURE_SCHEMA_VERSION = "campus-agent-staging-fixture/v1"
STAGING_GATE_SCHEMA_VERSION = "campus-agent-staging-gate/v1"

REQUIRED_FAILURE_CLASSES = (
    "provider_timeout",
    "provider_stream_reset",
    "retrieval_timeout",
    "tool_timeout",
    "tool_error",
    "authorization_denied",
    "knowledge_stale",
    "network_disconnected",
    "context_limit",
    "cancelled",
    "reconnect",
)

REQUIRED_FLAG_KEYS = (
    "AI_AGENT_ENABLED",
    "AI_LANGCHAIN_RAG_ENABLED",
    "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT",
    "AI_LEGACY_RAG_ENABLED",
    "RAG_RERANKER_ENABLED",
    "RAG_SHADOW_INDEX_ENABLED",
    "RAG_ALLOW_LANGSMITH",
)

_FORBIDDEN_FIELD_PARTS = {
    "account",
    "answer",
    "cookie",
    "credential",
    "dsn",
    "grade",
    "jwt",
    "password",
    "prompt",
    "question",
    "secret",
    "student",
    "subject",
    "token",
}


class AgentStagingGateError(ValueError):
    """A4 staging 证据不完整或违反安全边界。"""


def _reject_sensitive_fields(value: Any, path: str = "$") -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            normalized = str(key).casefold().replace("-", "_")
            if {part for part in normalized.split("_") if part} & _FORBIDDEN_FIELD_PARTS:
                raise AgentStagingGateError(f"staging 证据包含禁止字段：{path}.{key}")
            _reject_sensitive_fields(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_sensitive_fields(child, f"{path}[{index}]")


def _require_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AgentStagingGateError(f"字段 {field} 必须是非空字符串")
    return value.strip()


def _require_bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise AgentStagingGateError(f"字段 {field} 必须是布尔值")
    return value


def _require_number(value: Any, field: str, *, minimum: float = 0.0, maximum: float | None = None) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise AgentStagingGateError(f"字段 {field} 必须是数字")
    number = float(value)
    if number < minimum or (maximum is not None and number > maximum):
        raise AgentStagingGateError(f"字段 {field} 超出范围")
    return number


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AgentStagingGateError(f"无法读取 staging fixture：{path}: {exc}") from exc
    if not isinstance(value, dict):
        raise AgentStagingGateError("staging fixture 根节点必须是对象")
    _reject_sensitive_fields(value)
    return value


def _validate_snapshot(snapshot: Any, field: str) -> dict[str, Any]:
    if not isinstance(snapshot, Mapping):
        raise AgentStagingGateError(f"{field} 必须是对象")
    code_version = _require_string(snapshot.get("code_version"), f"{field}.code_version")
    knowledge_version = _require_string(snapshot.get("knowledge_version"), f"{field}.knowledge_version")
    flags = snapshot.get("flags")
    if not isinstance(flags, Mapping):
        raise AgentStagingGateError(f"{field}.flags 必须是对象")
    missing = [key for key in REQUIRED_FLAG_KEYS if key not in flags]
    if missing:
        raise AgentStagingGateError(f"{field}.flags 缺少：{missing}")
    normalized_flags: dict[str, Any] = {}
    for key in REQUIRED_FLAG_KEYS:
        value = flags[key]
        if not isinstance(value, (str, bool, int, float)) or isinstance(value, (list, dict)):
            raise AgentStagingGateError(f"{field}.flags.{key} 必须是标量")
        normalized_flags[key] = value
    return {
        "code_version": code_version,
        "knowledge_version": knowledge_version,
        "flags": normalized_flags,
    }


def _validate_faults(raw_faults: Any) -> list[dict[str, Any]]:
    if not isinstance(raw_faults, list) or not raw_faults:
        raise AgentStagingGateError("fault_injection 必须是非空数组")
    records: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_classes: set[str] = set()
    for index, raw in enumerate(raw_faults):
        if not isinstance(raw, Mapping):
            raise AgentStagingGateError(f"fault_injection[{index}] 必须是对象")
        case_id = _require_string(raw.get("case_id"), f"fault_injection[{index}].case_id")
        if case_id in seen_ids:
            raise AgentStagingGateError(f"故障场景 case_id 重复：{case_id}")
        seen_ids.add(case_id)
        failure_class = _require_string(raw.get("failure_class"), f"fault_injection[{index}].failure_class")
        if failure_class not in REQUIRED_FAILURE_CLASSES:
            raise AgentStagingGateError(f"未知故障分类：{failure_class}")
        seen_classes.add(failure_class)
        injected = _require_bool(raw.get("injected"), f"fault_injection[{index}].injected")
        recovered = _require_bool(raw.get("recovered"), f"fault_injection[{index}].recovered")
        classified = _require_bool(raw.get("classified"), f"fault_injection[{index}].classified")
        trace_recorded = _require_bool(raw.get("trace_recorded"), f"fault_injection[{index}].trace_recorded")
        exposed = _require_bool(raw.get("sensitive_data_exposed", False), f"fault_injection[{index}].sensitive_data_exposed")
        recovery_path = _require_string(raw.get("recovery_path"), f"fault_injection[{index}].recovery_path")
        user_status = _require_string(raw.get("user_status"), f"fault_injection[{index}].user_status")
        records.append(
            {
                "case_id": case_id,
                "failure_class": failure_class,
                "injected": injected,
                "recovered": recovered,
                "classified": classified,
                "trace_recorded": trace_recorded,
                "sensitive_data_exposed": exposed,
                "recovery_path": recovery_path,
                "user_status": user_status,
            }
        )
    missing = sorted(set(REQUIRED_FAILURE_CLASSES) - seen_classes)
    if missing:
        raise AgentStagingGateError(f"故障注入未覆盖分类：{missing}")
    return records


def _validate_observability(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, Mapping):
        raise AgentStagingGateError("observability 必须是对象")
    trace_linkage = _require_number(raw.get("trace_linkage_rate"), "observability.trace_linkage_rate", maximum=1.0)
    classification = _require_number(raw.get("classification_coverage"), "observability.classification_coverage", maximum=1.0)
    redaction = _require_string(raw.get("redaction_scan"), "observability.redaction_scan")
    if redaction not in {"pass", "fail"}:
        raise AgentStagingGateError("observability.redaction_scan 只能为 pass/fail")
    return {
        "trace_linkage_rate": trace_linkage,
        "classification_coverage": classification,
        "redaction_scan": redaction,
    }


def _validate_rollback(raw: Any, initial: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(raw, Mapping):
        raise AgentStagingGateError("rollback 必须是对象")
    point = _require_string(raw.get("rollback_point"), "rollback.rollback_point")
    recovered = _require_bool(raw.get("recovered"), "rollback.recovered")
    recovery_time_ms = _require_number(raw.get("recovery_time_ms"), "rollback.recovery_time_ms")
    before = _validate_snapshot(raw.get("before"), "rollback.before")
    after = _validate_snapshot(raw.get("after"), "rollback.after")
    if before != dict(initial):
        raise AgentStagingGateError("rollback.before 必须与入口版本快照一致")
    if before == after:
        raise AgentStagingGateError("rollback.after 必须体现回滚到固定旧版本")
    return {
        "rollback_point": point,
        "recovered": recovered,
        "recovery_time_ms": recovery_time_ms,
        "before": before,
        "after": after,
    }


def evaluate_staging_gate(fixture: Mapping[str, Any]) -> dict[str, Any]:
    """校验 A4 fixture，并生成可被 staging/灰度流程消费的门禁报告。"""

    _reject_sensitive_fields(fixture)
    if fixture.get("schema_version") != STAGING_FIXTURE_SCHEMA_VERSION:
        raise AgentStagingGateError("staging fixture schema_version 不匹配")
    evidence_type = _require_string(fixture.get("evidence_type", "fixture"), "evidence_type")
    if evidence_type not in {"fixture", "staging", "online"}:
        raise AgentStagingGateError("evidence_type 必须是 fixture/staging/online")
    initial = _validate_snapshot(fixture.get("snapshot"), "snapshot")
    faults = _validate_faults(fixture.get("fault_injection"))
    observability = _validate_observability(fixture.get("observability"))
    rollback = _validate_rollback(fixture.get("rollback"), initial)
    side_effects = fixture.get("side_effects", {})
    if not isinstance(side_effects, Mapping):
        raise AgentStagingGateError("side_effects 必须是对象")
    requests_performed = side_effects.get("requests_performed", 0)
    deployment_mutations = side_effects.get("deployment_mutations", 0)
    writes_performed = side_effects.get("writes_performed", False)
    if not isinstance(requests_performed, int) or requests_performed < 0:
        raise AgentStagingGateError("side_effects.requests_performed 必须是非负整数")
    if not isinstance(deployment_mutations, int) or deployment_mutations < 0:
        raise AgentStagingGateError("side_effects.deployment_mutations 必须是非负整数")
    if not isinstance(writes_performed, bool):
        raise AgentStagingGateError("side_effects.writes_performed 必须是布尔值")

    blocking_reasons: list[dict[str, Any]] = []
    version_gate = bool(initial["code_version"] and initial["knowledge_version"] and initial["flags"])
    if not version_gate:
        blocking_reasons.append({"gate": "version_snapshot", "reason": "版本或开关快照不完整"})
    fault_gate = all(
        item["injected"]
        and item["recovered"]
        and item["classified"]
        and item["trace_recorded"]
        and not item["sensitive_data_exposed"]
        for item in faults
    )
    if not fault_gate:
        blocking_reasons.append({"gate": "fault_injection", "reason": "故障未恢复、未分类、未记录或存在敏感数据暴露"})
    observability_gate = (
        observability["trace_linkage_rate"] >= 1.0
        and observability["classification_coverage"] >= 1.0
        and observability["redaction_scan"] == "pass"
    )
    if not observability_gate:
        blocking_reasons.append({"gate": "observability", "reason": "Trace 关联、分类覆盖或脱敏扫描未通过"})
    rollback_gate = bool(rollback["rollback_point"] and rollback["recovered"] and rollback["recovery_time_ms"] >= 0)
    if not rollback_gate:
        blocking_reasons.append({"gate": "rollback", "reason": "回滚点或回滚恢复记录不完整"})
    side_effect_gate = requests_performed == 0 and deployment_mutations == 0 and writes_performed is False
    if not side_effect_gate:
        blocking_reasons.append({"gate": "side_effects", "reason": "dry-run 产生了请求或部署变更"})

    gates = {
        "version_snapshot": "pass" if version_gate else "fail",
        "fault_injection": "pass" if fault_gate else "fail",
        "observability": "pass" if observability_gate else "fail",
        "rollback": "pass" if rollback_gate else "fail",
        "side_effects": "pass" if side_effect_gate else "fail",
    }
    blocked = bool(blocking_reasons)
    return {
        "schema_version": STAGING_GATE_SCHEMA_VERSION,
        "evidence_type": evidence_type,
        "mode": "dry_run",
        "code_version": initial["code_version"],
        "knowledge_version": initial["knowledge_version"],
        "flags_snapshot": initial["flags"],
        "failure_classes": [item["failure_class"] for item in faults],
        "fault_injection": faults,
        "observability": observability,
        "rollback": rollback,
        "gates": gates,
        "blocked": blocked,
        "decision": "blocked" if blocked else "pass",
        "blocking_reasons": blocking_reasons,
        "requests_performed": requests_performed,
        "deployment_mutations": deployment_mutations,
        "writes_performed": writes_performed,
    }


def load_and_evaluate(path: Path) -> dict[str, Any]:
    try:
        fixture = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AgentStagingGateError(f"无法读取 staging fixture：{path}: {exc}") from exc
    if not isinstance(fixture, Mapping):
        raise AgentStagingGateError("staging fixture 根节点必须是对象")
    return evaluate_staging_gate(fixture)


__all__ = [
    "REQUIRED_FAILURE_CLASSES",
    "REQUIRED_FLAG_KEYS",
    "STAGING_FIXTURE_SCHEMA_VERSION",
    "STAGING_GATE_SCHEMA_VERSION",
    "AgentStagingGateError",
    "evaluate_staging_gate",
    "load_and_evaluate",
]
