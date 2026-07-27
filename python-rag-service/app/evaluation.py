from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from langchain_core.embeddings import Embeddings

from app.retrievers import HybridPolicyRetriever, RetrievalCandidate


class _FixtureEmbeddings(Embeddings):
    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [[0.0, 0.0, 0.0] for _ in texts]

    def embed_query(self, text: str) -> list[float]:
        return self.embed_documents([text])[0]


class _FixtureSearchStore:
    def __init__(self, candidates: list[RetrievalCandidate]) -> None:
        self._candidates = candidates

    def exact_search(self, plan, limit):
        del plan
        return self._candidates[:limit]

    def fts_search(self, plan, fts_query, limit):
        del plan, fts_query
        return self._candidates[:limit]

    def vector_search(self, plan, embedding, model_version, dimensions, limit):
        del plan, embedding, model_version, dimensions
        return self._candidates[:limit]

    def trigram_search(self, plan, limit):
        del plan
        return self._candidates[:limit]


def _candidate(item: dict[str, Any]) -> RetrievalCandidate:
    historical = bool(item.get("historical", False))
    return RetrievalCandidate(
        chunk_id=int(item["chunk_id"]),
        document_id=int(item.get("document_id", item["chunk_id"])),
        content=str(item.get("content", "fixture")),
        title=str(item.get("title", "fixture")),
        document_type=str(item.get("document_type", "")),
        source_type="official_historical_compilation" if historical else "official",
        source_locator=str(item.get("source_locator", "")),
        historical=historical,
    )


def evaluate_shared_fixture(directory: Path, *, k: int = 5) -> dict[str, Any]:
    cases: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                value = json.loads(line)
                if value.get("kind") == "policy":
                    cases.append(value)

    relevant_total = 0
    relevant_hit = 0
    ranked_cases = 0
    reciprocal_rank = 0.0
    failures: list[str] = []
    categories: dict[str, int] = {}
    for case in cases:
        category = str(case.get("category", "policy"))
        categories[category] = categories.get(category, 0) + 1
        candidates = [
            _candidate(item) for item in case.get("fixture", {}).get("retrieved", [])
        ]
        retriever = HybridPolicyRetriever(
            search_store=_FixtureSearchStore(candidates),
            embeddings=_FixtureEmbeddings(),
            embedding_model_version="fixture-3-v1",
            k=k,
        )
        documents = retriever.invoke(str(case["question"]))
        top_types = [
            str(document.metadata.get("document_type", ""))
            for document in documents[:k]
        ]
        targets = [str(value) for value in case.get("target_document_types", [])]
        relevant_total += len(targets)
        first_rank = 0
        for target in targets:
            if target in top_types:
                relevant_hit += 1
                rank = top_types.index(target) + 1
                first_rank = rank if first_rank == 0 else min(first_rank, rank)
            else:
                failures.append(str(case.get("id", "unknown")))
        if targets:
            ranked_cases += 1
            if first_rank:
                reciprocal_rank += 1 / first_rank

    return {
        "schema_version": "1.0",
        "mode": "langchain_fixture",
        "k": k,
        "cases": len(cases),
        "categories": categories,
        "relevant_targets": relevant_total,
        "retrieved_targets": relevant_hit,
        "recall_at_k": relevant_hit / relevant_total if relevant_total else 1.0,
        "mrr": reciprocal_rank / ranked_cases if ranked_cases else 1.0,
        "failures": sorted(set(failures)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="运行 LangChain 共享 fixture 检索评测")
    parser.add_argument("--data", type=Path, default=Path("../server/testdata/ai_eval"))
    parser.add_argument("--k", type=int, default=5)
    arguments = parser.parse_args()
    if arguments.k <= 0:
        parser.error("--k 必须大于 0")
    report = evaluate_shared_fixture(arguments.data, k=arguments.k)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
