"""运行校园 Agent A4 staging 门禁（默认 dry-run）。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _import_gate():
    service_root = Path(__file__).resolve().parents[1] / "python-rag-service"
    if str(service_root) not in sys.path:
        sys.path.insert(0, str(service_root))
    from app.agent_staging_gate import AgentStagingGateError, load_and_evaluate

    return AgentStagingGateError, load_and_evaluate


def main() -> int:
    parser = argparse.ArgumentParser(description="校园 Agent A4 staging 故障与回滚门禁")
    parser.add_argument(
        "--fixture",
        type=Path,
        default=Path("server/testdata/ai_eval/agent_staging/staging_gate.fixture.json"),
        help="脱敏故障注入 fixture；不会发起网络请求",
    )
    parser.add_argument("--report", type=Path, help="写出门禁 JSON，目标必须不存在")
    args = parser.parse_args()
    AgentStagingGateError, load_and_evaluate = _import_gate()
    try:
        report = load_and_evaluate(args.fixture)
        encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.report:
            if args.report.exists():
                raise AgentStagingGateError(f"报告路径必须不存在：{args.report}")
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(encoded, encoding="utf-8", newline="\n")
        print(encoded, end="")
        return 1 if report["blocked"] else 0
    except AgentStagingGateError as exc:
        print(f"A4 staging 门禁失败：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
