from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import jieba
from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings

from app.chains import PolicyQueryPlanner
from app.rerankers import (
    POLICY_DOCUMENT_TYPE_LABEL_VERSION,
    PolicyReranker,
    policy_document_type_label,
)
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


class FixturePolicyRerankModel:
    """共享评测的确定性模型，只用于离线校准，不访问网络或模型缓存。"""

    model_name = "fixture-policy-reranker"
    model_version = "policy-domain-overlap-v1"

    def __init__(self) -> None:
        self._planner = PolicyQueryPlanner()

    def score(self, query: str, documents: list[str]) -> list[float]:
        plan = self._planner.invoke(query)
        # 扩展词用于提高召回，重排阶段仍以原问题为主，避免宽泛扩展词淹没直接证据。
        query_tokens = _semantic_tokens(plan.normalized_question)
        expanded_tokens = _semantic_tokens(plan.retrieval_query)
        scores: list[float] = []
        for document in documents:
            document_tokens = _semantic_tokens(document)
            overlap = len(query_tokens & document_tokens)
            coverage = overlap / max(1, min(len(query_tokens), 8))
            preferred_rank = next(
                (
                    index
                    for index, document_type in enumerate(plan.preferred_document_types)
                    if policy_document_type_label(document_type) in document
                ),
                None,
            )
            if preferred_rank is not None:
                expanded_overlap = len(expanded_tokens & document_tokens)
                expanded_coverage = expanded_overlap / max(
                    1, min(len(expanded_tokens), 8)
                )
                score = (
                    0.5
                    + min(max(coverage, expanded_coverage) * 0.45, 0.42)
                    + max(0.0, 0.04 - min(preferred_rank, 4) * 0.01)
                )
            else:
                score = 0.08 + min(coverage * 0.9, 0.72)
            scores.append(round(min(score, 0.99), 6))
        return scores


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


def _document(item: dict[str, Any]) -> Document:
    candidate = _candidate(item)
    return Document(
        page_content=candidate.content,
        metadata={
            "source_id": f"chunk:{candidate.chunk_id}",
            "chunk_id": candidate.chunk_id,
            "document_id": candidate.document_id,
            "title": candidate.title,
            "document_type": candidate.document_type,
            "source_locator": candidate.source_locator,
            "historical": candidate.historical,
            "degraded_modes": [],
        },
    )


def _load_policy_cases(directory: Path) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                value = json.loads(line)
                if value.get("kind") == "policy":
                    cases.append(value)
    return cases


def evaluate_shared_fixture(directory: Path, *, k: int = 5) -> dict[str, Any]:
    cases = _load_policy_cases(directory)

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


def evaluate_reranker_fixture(
    directory: Path, *, k: int = 5, rerank_model: Any | None = None
) -> dict[str, Any]:
    """使用 T01 用例构造含干扰候选的校准池，并报告排序与拒答门禁指标。"""

    cases = _load_policy_cases(directory)
    corpus: list[Document] = []
    seen_chunks: set[int] = set()
    for case in cases:
        for item in case.get("fixture", {}).get("retrieved", []):
            chunk_id = int(item["chunk_id"])
            if chunk_id not in seen_chunks:
                seen_chunks.add(chunk_id)
                corpus.append(_document(item))

    selected_model = rerank_model or FixturePolicyRerankModel()
    planner = PolicyQueryPlanner()
    reranker = PolicyReranker(
        rerank_model=selected_model,
        model_name=str(selected_model.model_name),
        model_version=str(selected_model.model_version),
        top_n=20,
        max_candidates=20,
        timeout_seconds=2,
        query_transform=lambda question: planner.invoke(question).retrieval_query,
        query_strategy="policy-planned-query-v1",
    )
    evaluated: list[dict[str, Any]] = []
    for case in cases:
        own = [_document(item) for item in case.get("fixture", {}).get("retrieved", [])]
        own_chunks = {int(document.metadata["chunk_id"]) for document in own}
        target_types = {str(value) for value in case.get("target_document_types", [])}
        plan = planner.invoke(str(case["question"]))
        # T01 只标注文档类型目标；同一规划域内的其他文档不能擅自标成负样本。
        excluded_distractor_types = target_types | set(plan.preferred_document_types)
        distractors = [
            document
            for document in corpus
            if int(document.metadata["chunk_id"]) not in own_chunks
            and str(document.metadata.get("document_type", ""))
            not in excluded_distractor_types
        ]
        if own:
            candidates = [*distractors[:4], *own, *distractors[4:20]]
        else:
            candidates = corpus[:20]
        candidates = candidates[:20]
        reranked = list(reranker.compress_documents(candidates, str(case["question"])))
        scores = [float(document.metadata["rerank_score"]) for document in reranked]
        evaluated.append(
            {
                "id": str(case["id"]),
                "category": str(case.get("category", "policy")),
                "should_refuse": bool(case.get("should_refuse", False)),
                "targets": list(target_types),
                "before": candidates,
                "after": reranked,
                "top_score": max(scores, default=0.0),
            }
        )

    threshold = _calibrate_threshold(evaluated)
    gate_failures: list[str] = []
    false_accepts: list[str] = []
    false_rejects: list[str] = []
    answerable = 0
    answerable_accepted = 0
    negatives = 0
    negatives_rejected = 0
    for item in evaluated:
        accepted = item["top_score"] >= threshold
        expected_accept = not item["should_refuse"]
        if expected_accept:
            answerable += 1
            answerable_accepted += int(accepted)
            if not accepted:
                false_rejects.append(item["id"])
        else:
            negatives += 1
            negatives_rejected += int(not accepted)
            if accepted:
                false_accepts.append(item["id"])
        if accepted != expected_accept:
            gate_failures.append(item["id"])

    before = _ranking_metrics(evaluated, key="before", k=k)
    after = _ranking_metrics(evaluated, key="after", k=k)
    core = [item for item in evaluated if item["category"] == "v06_core"]
    return {
        "schema_version": "1.0",
        "mode": "langchain_reranker_fixture_calibration",
        "data_source": "T01 shared policy JSONL",
        "model": reranker.model_name,
        "model_version": reranker.model_version,
        "query_strategy": reranker.query_strategy,
        "document_type_label_version": POLICY_DOCUMENT_TYPE_LABEL_VERSION,
        "score_range": [0.0, 1.0],
        "threshold_comparison": "score >= threshold",
        "relevance_threshold": threshold,
        "cases": len(evaluated),
        "answerable_cases": answerable,
        "negative_cases": negatives,
        "gate_accuracy": (len(evaluated) - len(gate_failures)) / len(evaluated),
        "answerable_recall": answerable_accepted / answerable if answerable else 1.0,
        "negative_rejection_rate": negatives_rejected / negatives if negatives else 1.0,
        "false_accepts": false_accepts,
        "false_rejects": false_rejects,
        "ranking_before": before,
        "ranking_after": after,
        "v06_core_after": _ranking_metrics(core, key="after", k=k),
        "failures": sorted(set(gate_failures + after["failures"])),
    }


def _semantic_tokens(text: str) -> set[str]:
    ignored = {"什么", "怎么", "能否", "是否", "规定", "学校", "学生", "实际"}
    return {
        token.casefold()
        for token in jieba.cut_for_search(text)
        if (
            len(token.strip()) >= 2
            or (len(token.strip()) == 1 and token.isascii() and token.isalnum())
        )
        and token.casefold() not in ignored
    }


def _calibrate_threshold(evaluated: list[dict[str, Any]]) -> float:
    scores = sorted({float(item["top_score"]) for item in evaluated})
    candidates = {0.0, 1.0}
    candidates.update(scores)
    candidates.update((left + right) / 2 for left, right in zip(scores, scores[1:]))
    best_threshold = 0.5
    best_key = (-1.0, -1, -1, -1.0)
    answerable_total = sum(not bool(item["should_refuse"]) for item in evaluated)
    negative_total = sum(bool(item["should_refuse"]) for item in evaluated)
    for threshold in sorted(candidates):
        correct = 0
        accepted_answerable = 0
        rejected_negative = 0
        for item in evaluated:
            accepted = float(item["top_score"]) >= threshold
            expected = not bool(item["should_refuse"])
            correct += int(accepted == expected)
            accepted_answerable += int(expected and accepted)
            rejected_negative += int(not expected and not accepted)
        answerable_recall = accepted_answerable / max(1, answerable_total)
        negative_rejection = rejected_negative / max(1, negative_total)
        key = (
            answerable_recall + negative_rejection,
            rejected_negative,
            correct,
            threshold,
        )
        if key > best_key:
            best_key = key
            best_threshold = threshold
    return round(best_threshold, 6)


def _ranking_metrics(
    evaluated: list[dict[str, Any]], *, key: str, k: int
) -> dict[str, Any]:
    relevant_total = 0
    relevant_hit = 0
    reciprocal_rank = 0.0
    ranked_cases = 0
    failures: list[str] = []
    for item in evaluated:
        targets = item["targets"]
        if not targets:
            continue
        ranked_cases += 1
        top_types = [
            str(document.metadata.get("document_type", ""))
            for document in item[key][:k]
        ]
        relevant_total += len(targets)
        ranks: list[int] = []
        for target in targets:
            if target in top_types:
                relevant_hit += 1
                ranks.append(top_types.index(target) + 1)
            else:
                failures.append(item["id"])
        if ranks:
            reciprocal_rank += 1 / min(ranks)
    return {
        "k": k,
        "ranked_cases": ranked_cases,
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
    parser.add_argument(
        "--calibrate-reranker",
        action="store_true",
        help="使用 T01 共享评测集校准离线相关性阈值",
    )
    arguments = parser.parse_args()
    if arguments.k <= 0:
        parser.error("--k 必须大于 0")
    report = (
        evaluate_reranker_fixture(arguments.data, k=arguments.k)
        if arguments.calibrate_reranker
        else evaluate_shared_fixture(arguments.data, k=arguments.k)
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
