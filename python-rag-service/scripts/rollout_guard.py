from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping


STATE_SCHEMA_VERSION = "t09-rollout-state/v1"
EVIDENCE_SCHEMA_VERSION = "t09-rollout-evidence/v1"
AGENT_QUALITY_SCHEMA_VERSION = "campus-agent-quality-gate/v1"
STAGES = ("off", "internal", "5", "20", "50", "100")
REQUIRED_GATES = (
    "quality",
    "error_rate",
    "latency",
    "cost",
    "observability",
    "security_regression",
    "rollback_drills",
    "shadow_index_comparison",
)


class RolloutGuardError(ValueError):
    """灰度证据或阶段顺序不满足发布约束。"""


def validate_agent_quality_report(
    value: Mapping[str, Any], *, require_pass: bool = True, require_runtime_evidence: bool = False
) -> None:
    """校验 A3 报告，避免质量失败时继续扩大 Agent 灰度。"""

    if value.get("schema_version") != AGENT_QUALITY_SCHEMA_VERSION:
        raise RolloutGuardError("invalid agent quality report schema")
    evidence_type = value.get("evidence_type")
    if evidence_type not in {"fixture", "staging", "online"}:
        raise RolloutGuardError("invalid agent quality evidence type")
    if require_runtime_evidence and evidence_type == "fixture":
        raise RolloutGuardError("fixture quality evidence cannot advance runtime rollout")
    gates = value.get("gates")
    if not isinstance(gates, Mapping) or not gates:
        raise RolloutGuardError("agent quality report gates are required")
    invalid = [name for name, result in gates.items() if result not in {"pass", "fail"}]
    if invalid:
        raise RolloutGuardError("invalid agent quality gate results: " + ",".join(sorted(invalid)))
    if not isinstance(value.get("blocked"), bool):
        raise RolloutGuardError("agent quality blocked flag is required")
    if require_pass and (value.get("blocked") is True or any(result != "pass" for result in gates.values())):
        failed = [name for name, result in gates.items() if result != "pass"]
        raise RolloutGuardError("agent quality gates not passed: " + ",".join(sorted(failed)) or "agent quality blocked")
    for field in ("knowledge_version", "publish_decision", "rollout_decision"):
        if field not in value:
            raise RolloutGuardError(f"agent quality report field is required: {field}")
    if require_pass and value.get("publish_decision") == "blocked":
        raise RolloutGuardError("agent quality publish decision is blocked")
    if require_pass and value.get("rollout_decision") == "blocked":
        raise RolloutGuardError("agent quality rollout decision is blocked")


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema_version": STATE_SCHEMA_VERSION, "current_stage": "off", "history": []}
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schema_version") != STATE_SCHEMA_VERSION:
        raise RolloutGuardError("invalid rollout state schema")
    if value.get("current_stage") not in STAGES:
        raise RolloutGuardError("invalid current rollout stage")
    if not isinstance(value.get("history"), list):
        raise RolloutGuardError("invalid rollout history")
    return value


def validate_transition(current: str, target: str) -> None:
    if target == "rollback":
        if current == "off":
            raise RolloutGuardError("rollout is already off")
        return
    if target not in STAGES[1:]:
        raise RolloutGuardError("invalid target rollout stage")
    expected = STAGES[STAGES.index(current) + 1] if current != STAGES[-1] else ""
    if target != expected:
        raise RolloutGuardError(f"next rollout stage must be {expected or 'none'}")


def validate_evidence(
    value: Mapping[str, Any], current: str, *, require_pass: bool = True
) -> None:
    if value.get("schema_version") != EVIDENCE_SCHEMA_VERSION:
        raise RolloutGuardError("invalid rollout evidence schema")
    expected_stage = "preflight" if current == "off" else current
    if value.get("stage") != expected_stage:
        raise RolloutGuardError(f"evidence stage must be {expected_stage}")
    gates = value.get("gates")
    if not isinstance(gates, Mapping):
        raise RolloutGuardError("rollout evidence gates are required")
    invalid = [name for name in REQUIRED_GATES if gates.get(name) not in {"pass", "fail"}]
    if invalid:
        raise RolloutGuardError("invalid rollout gate results: " + ",".join(invalid))
    if require_pass:
        failed = [name for name in REQUIRED_GATES if gates.get(name) != "pass"]
        if failed:
            raise RolloutGuardError("rollout gates not passed: " + ",".join(failed))
    sample_size = value.get("sample_size")
    if not isinstance(sample_size, int) or sample_size < 0:
        raise RolloutGuardError("invalid evidence sample size")
    if require_pass and current != "off" and sample_size <= 0:
        raise RolloutGuardError("observed rollout stage requires a non-zero sample")


def environment_for_stage(stage: str) -> dict[str, str]:
    if stage == "off":
        return {
            "AI_LANGCHAIN_RAG_ENABLED": "false",
            "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT": "0",
            "AI_LEGACY_RAG_ENABLED": "true",
        }
    if stage == "internal":
        return {
            "AI_LANGCHAIN_RAG_ENABLED": "true",
            "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT": "100",
            "AI_LEGACY_RAG_ENABLED": "true",
        }
    return {
        "AI_LANGCHAIN_RAG_ENABLED": "true",
        "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT": stage,
        # 到达 100% 后仍保留旧路径，完成观察窗口后才能另行评审是否移除。
        "AI_LEGACY_RAG_ENABLED": "true",
    }


def evidence_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def advance_state(
    state: dict[str, Any],
    target: str,
    evidence_path: Path,
    agent_quality_path: Path | None = None,
) -> dict[str, Any]:
    current = str(state["current_stage"])
    validate_transition(current, target)
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    # 推进必须全部通过；紧急回滚只要求证据结构有效，不能因故障门禁为 fail 而被阻止。
    validate_evidence(evidence, current, require_pass=target != "rollback")
    next_stage = "off" if target == "rollback" else target
    history = list(state["history"])
    history_item = {
            "from": current,
            "to": next_stage,
            "evidence_sha256": evidence_digest(evidence_path),
            "advanced_at": datetime.now(timezone.utc).isoformat(),
        }
    if agent_quality_path is not None:
        quality_value = json.loads(agent_quality_path.read_text(encoding="utf-8"))
        if not isinstance(quality_value, Mapping):
            raise RolloutGuardError("agent quality report must be an object")
        validate_agent_quality_report(
            quality_value,
            require_pass=target != "rollback",
            require_runtime_evidence=target != "rollback",
        )
        history_item["agent_quality_sha256"] = evidence_digest(agent_quality_path)
        history_item["agent_quality_knowledge_version"] = str(quality_value["knowledge_version"])
    history.append(history_item)
    return {
        "schema_version": STATE_SCHEMA_VERSION,
        "current_stage": next_stage,
        "history": history,
    }


def write_state_atomic(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="T09 LangChain 顺序灰度门禁")
    parser.add_argument("--state", type=Path, required=True, help="本地灰度状态记录")
    parser.add_argument("--target", required=True, choices=(*STAGES[1:], "rollback"))
    parser.add_argument("--evidence", type=Path, help="上一阶段的脱敏门禁证据 JSON")
    parser.add_argument(
        "--agent-quality-report",
        type=Path,
        help="A3 Agent 质量门禁报告；扩大运行时灰度时必须来自 staging/online",
    )
    parser.add_argument(
        "--require-agent-quality",
        action="store_true",
        help="Agent 灰度推进时强制要求 A3 质量报告",
    )
    parser.add_argument("--advance", action="store_true", help="写入下一阶段状态；默认仅预览")
    parser.add_argument("--confirm", default="", help="必须为 ADVANCE:<阶段> 或 ROLLBACK")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        state = load_state(args.state)
        validate_transition(str(state["current_stage"]), args.target)
        effective_target = "off" if args.target == "rollback" else args.target
        plan = {
            "current_stage": state["current_stage"],
            "target_stage": effective_target,
            "writes_performed": False,
            "environment": environment_for_stage(effective_target),
        }
        if not args.advance:
            print(json.dumps(plan, ensure_ascii=False, indent=2))
            return 0
        required = "ROLLBACK" if args.target == "rollback" else f"ADVANCE:{args.target}"
        if args.confirm != required:
            raise RolloutGuardError(f"confirmation must be {required}")
        if args.evidence is None or not args.evidence.is_file():
            raise RolloutGuardError("rollout evidence file is required")
        if args.require_agent_quality and args.target != "rollback" and args.agent_quality_report is None:
            raise RolloutGuardError("Agent 灰度推进需要 --agent-quality-report")
        updated = advance_state(state, args.target, args.evidence, args.agent_quality_report)
        write_state_atomic(args.state, updated)
        plan["writes_performed"] = True
        plan["state_sha256"] = hashlib.sha256(args.state.read_bytes()).hexdigest()
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return 0
    except (OSError, json.JSONDecodeError, RolloutGuardError) as exc:
        print(f"rollout guard blocked: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
