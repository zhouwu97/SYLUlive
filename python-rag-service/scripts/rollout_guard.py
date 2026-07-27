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
            "AI_INTERNAL_TEST_ONLY": "false",
            "AI_LANGCHAIN_RAG_ENABLED": "false",
            "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT": "0",
            "AI_LEGACY_RAG_ENABLED": "true",
        }
    if stage == "internal":
        return {
            "AI_INTERNAL_TEST_ONLY": "true",
            "AI_LANGCHAIN_RAG_ENABLED": "true",
            "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT": "100",
            "AI_LEGACY_RAG_ENABLED": "true",
        }
    return {
        "AI_INTERNAL_TEST_ONLY": "false",
        "AI_LANGCHAIN_RAG_ENABLED": "true",
        "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT": stage,
        # 到达 100% 后仍保留旧路径，完成观察窗口后才能另行评审是否移除。
        "AI_LEGACY_RAG_ENABLED": "true",
    }


def evidence_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def advance_state(state: dict[str, Any], target: str, evidence_path: Path) -> dict[str, Any]:
    current = str(state["current_stage"])
    validate_transition(current, target)
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    # 推进必须全部通过；紧急回滚只要求证据结构有效，不能因故障门禁为 fail 而被阻止。
    validate_evidence(evidence, current, require_pass=target != "rollback")
    next_stage = "off" if target == "rollback" else target
    history = list(state["history"])
    history.append(
        {
            "from": current,
            "to": next_stage,
            "evidence_sha256": evidence_digest(evidence_path),
            "advanced_at": datetime.now(timezone.utc).isoformat(),
        }
    )
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
        updated = advance_state(state, args.target, args.evidence)
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
