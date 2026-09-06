"""运行校园 Agent A3 评测分片与独立质量门禁。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _import_quality_module():
    service_root = Path(__file__).resolve().parents[1] / "python-rag-service"
    if str(service_root) not in sys.path:
        sys.path.insert(0, str(service_root))
    from app.agent_quality import AgentQualityError, load_quality_dataset, run_quality_gate

    return AgentQualityError, load_quality_dataset, run_quality_gate


def main() -> int:
    parser = argparse.ArgumentParser(description="校园 Agent A3 独立质量门禁")
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("server/testdata/ai_eval/agent_quality_manifest.json"),
        help="calibration/holdout split manifest",
    )
    parser.add_argument("--report", type=Path, help="写出机器可读报告；目标必须不存在")
    args = parser.parse_args()
    AgentQualityError, load_quality_dataset, run_quality_gate = _import_quality_module()
    try:
        dataset = load_quality_dataset(args.manifest)
        report = run_quality_gate(dataset)
        encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.report:
            if args.report.exists():
                raise AgentQualityError(f"报告路径必须不存在：{args.report}")
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(encoded, encoding="utf-8", newline="\n")
        print(encoded, end="")
        return 1 if report["blocked"] else 0
    except AgentQualityError as exc:
        print(f"A3 质量门禁失败：{exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
