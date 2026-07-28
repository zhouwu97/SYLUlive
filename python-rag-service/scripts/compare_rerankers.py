from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from app.evaluation import evaluate_reranker_fixture, evaluate_shared_fixture
from app.rerankers import FastEmbedCrossEncoderRerankModel


DEFAULT_MODELS = (
    "Xenova/ms-marco-MiniLM-L-12-v2",
    "BAAI/bge-reranker-base",
)

MODEL_VERSIONS = {
    "Xenova/ms-marco-MiniLM-L-12-v2": "ms-marco-minilm-l12-v2-fastembed-v1",
    "BAAI/bge-reranker-base": "bge-reranker-base-fastembed-v1",
}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="使用 T01 共享评测集离线比较真实 CrossEncoder reranker"
    )
    parser.add_argument("--data", type=Path, default=Path("../server/testdata/ai_eval"))
    parser.add_argument("--k", type=int, default=5)
    parser.add_argument("--model", action="append", dest="models")
    parser.add_argument(
        "--live",
        action="store_true",
        help="显式允许执行真实模型推理",
    )
    parser.add_argument(
        "--allow-model-download",
        action="store_true",
        help="显式允许 FastEmbed 下载缺失模型；默认只读本地缓存",
    )
    parser.add_argument("--cache-dir", type=Path)
    arguments = parser.parse_args()
    if not arguments.live:
        parser.error("真实模型测试必须显式传入 --live")
    if arguments.k <= 0:
        parser.error("--k 必须大于 0")

    reports: list[dict[str, Any]] = []
    failed = False
    for model_name in arguments.models or DEFAULT_MODELS:
        try:
            model = FastEmbedCrossEncoderRerankModel(
                model_name=model_name,
                model_version=MODEL_VERSIONS.get(model_name, model_name + "-fastembed-v1"),
                allow_model_download=arguments.allow_model_download,
                cache_dir=str(arguments.cache_dir) if arguments.cache_dir else None,
                batch_size=16,
                max_concurrency=1,
            )
            reports.append(
                evaluate_reranker_fixture(
                    arguments.data,
                    k=arguments.k,
                    rerank_model=model,
                )
            )
        except Exception as exc:
            failed = True
            reports.append(
                {
                    "model": model_name,
                    "status": "unavailable",
                    "error_class": type(exc).__name__,
                }
            )

    output = {
        "schema_version": "1.0",
        "mode": "local_live_reranker_comparison",
        "model_download_allowed": bool(arguments.allow_model_download),
        "t01_baseline": evaluate_shared_fixture(arguments.data, k=arguments.k),
        "models": reports,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))
    if failed or any(report.get("failures") for report in reports):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
