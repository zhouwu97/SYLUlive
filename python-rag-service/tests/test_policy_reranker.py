from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Sequence
from pathlib import Path

import pytest
from langchain_core.documents import Document
from langchain_core.documents.compressor import BaseDocumentCompressor
from pydantic import PrivateAttr

from app.chains import astream_policy_events, build_policy_rag_chain
from app.evaluation import evaluate_reranker_fixture
from app.providers import FakePolicyChatModel
from app.rerankers import FastEmbedCrossEncoderRerankModel, PolicyReranker
from app.retrievers import FakePolicyRetriever
from app.schemas import PolicyRAGInput


class _FixedRerankModel:
    model_name = "fixture"
    model_version = "fixture-v1"

    def __init__(self, scores: Sequence[float]) -> None:
        self.scores = list(scores)
        self.calls = 0
        self.document_counts: list[int] = []
        self.queries: list[str] = []
        self.documents: list[list[str]] = []

    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]:
        self.calls += 1
        self.document_counts.append(len(documents))
        self.queries.append(query)
        self.documents.append(list(documents))
        return self.scores[: len(documents)]


class _FailingRerankModel:
    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]:
        del query, documents
        raise ConnectionError("fixture network failure")


class _SlowRerankModel:
    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]:
        del query
        time.sleep(0.1)
        return [0.9] * len(documents)


class _BlockingAsyncRerankModel:
    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.cancelled = asyncio.Event()

    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]:
        raise AssertionError("异步测试不应调用同步接口")

    async def ascore(
        self, query: str, documents: Sequence[str]
    ) -> Sequence[float]:
        del query, documents
        self.started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            self.cancelled.set()
            raise


class _CountingChatModel(FakePolicyChatModel):
    _calls: int = PrivateAttr(default=0)

    @property
    def calls(self) -> int:
        return self._calls

    def _generate(self, *args, **kwargs):
        self._calls += 1
        return super()._generate(*args, **kwargs)


def _document(chunk_id: int, content: str | None = None) -> Document:
    return Document(
        page_content=content or f"政策证据 {chunk_id}",
        metadata={
            "source_id": f"chunk:{chunk_id}",
            "chunk_id": chunk_id,
            "document_id": chunk_id,
            "title": "测试政策",
            "document_type": "school_test_policy",
            "degraded_modes": [],
        },
    )


def _reranker(model, **kwargs) -> PolicyReranker:
    return PolicyReranker(
        rerank_model=model,
        model_name="fixture",
        model_version="fixture-v1",
        timeout_seconds=kwargs.pop("timeout_seconds", 1),
        **kwargs,
    )


def test_policy_reranker_is_langchain_compressor_and_limits_candidates():
    model = _FixedRerankModel([0.5, 0.9, *([0.5] * 18)])
    reranker = _reranker(model, top_n=20, max_candidates=20)
    documents = [_document(index) for index in range(1, 26)]

    result = list(reranker.compress_documents(documents, "测试问题"))

    assert isinstance(reranker, BaseDocumentCompressor)
    assert model.document_counts == [20]
    assert len(result) == 20
    assert result[0].metadata["chunk_id"] == 2
    assert [item.metadata["chunk_id"] for item in result[1:4]] == [1, 3, 4]
    assert result[0].metadata["rerank_score"] == 0.9
    assert result[0].metadata["rerank_model_version"] == "fixture-v1"


def test_reranker_uses_planned_query_and_chinese_document_type_label():
    model = _FixedRerankModel([0.9])
    document = _document(1)
    document.metadata["document_type"] = "school_undergraduate_retake_policy"
    reranker = _reranker(
        model,
        query_transform=lambda question: f"{question} 课程重修",
        query_strategy="policy-planned-query-v1",
    )

    result = list(reranker.compress_documents([document], "重修"))

    assert model.queries == ["重修 课程重修"]
    assert "本科生课程重修政策" in model.documents[0][0]
    assert "school_undergraduate_retake_policy" not in model.documents[0][0]
    assert result[0].metadata["rerank_query_strategy"] == "policy-planned-query-v1"
    assert (
        result[0].metadata["rerank_document_type_label_version"]
        == "policy-document-type-zh-v1"
    )


def test_duplicate_candidates_are_removed_before_scoring():
    model = _FixedRerankModel([0.8, 0.7])
    reranker = _reranker(model)
    first = _document(1)

    result = list(
        reranker.compress_documents([first, first.model_copy(deep=True), _document(2)], "问题")
    )

    assert model.document_counts == [2]
    assert [item.metadata["chunk_id"] for item in result] == [1, 2]


def test_candidate_limit_is_applied_after_duplicate_removal():
    model = _FixedRerankModel([0.5] * 20)
    reranker = _reranker(model, top_n=20, max_candidates=20)
    first = _document(1)
    documents = [first, first.model_copy(deep=True), *[_document(index) for index in range(2, 21)]]

    result = list(reranker.compress_documents(documents, "问题"))

    assert model.document_counts == [20]
    assert len(result) == 20
    assert result[-1].metadata["chunk_id"] == 20


@pytest.mark.parametrize(
    "model",
    [
        _FailingRerankModel(),
        _FixedRerankModel([]),
        _FixedRerankModel(["not-a-score"]),
        _FixedRerankModel([float("nan")]),
        _FixedRerankModel([float("inf")]),
        _FixedRerankModel([-0.1]),
        _FixedRerankModel([1.1]),
    ],
)
def test_failure_and_abnormal_scores_fall_back_to_fused_order(model):
    result = list(_reranker(model).compress_documents([_document(1)], "问题"))

    assert result[0].metadata["chunk_id"] == 1
    assert result[0].metadata["rerank_applied"] is False
    assert result[0].metadata["degraded_modes"] == ["rerank"]
    assert "rerank_score" not in result[0].metadata


def test_reranker_timeout_has_stable_fallback():
    result = list(
        _reranker(_SlowRerankModel(), timeout_seconds=0.01).compress_documents(
            [_document(1)], "问题"
        )
    )

    assert result[0].metadata["degraded_modes"] == ["rerank"]
    assert result[0].metadata["rerank_applied"] is False


def test_empty_candidates_do_not_call_model():
    model = _FixedRerankModel([])

    assert list(_reranker(model).compress_documents([], "问题")) == []
    assert model.calls == 0


def test_query_transform_failure_degrades_without_calling_model():
    model = _FixedRerankModel([0.9])

    def fail_transform(_: str) -> str:
        raise ValueError("fixture planner failure")

    result = list(
        _reranker(model, query_transform=fail_transform).compress_documents(
            [_document(1)], "问题"
        )
    )

    assert model.calls == 0
    assert result[0].metadata["rerank_applied"] is False
    assert result[0].metadata["degraded_modes"] == ["rerank"]


@pytest.mark.parametrize(
    ("score", "expected_status", "expected_calls"),
    [(0.439999, "general_completed", 1), (0.44, "completed", 1)],
)
def test_runnable_branch_uses_inclusive_calibrated_threshold(
    score: float, expected_status: str, expected_calls: int
):
    chat_model = _CountingChatModel(
        response_text=json.dumps(
            {
                "answer": "有证据的回答。",
                "current_rules": [{"statement": "政策证据 1", "citation_ids": ["R1"]}],
                "historical_rules": [],
                "warnings": [],
                "citations": [{"reference_id": "R1", "quote": "政策证据 1"}],
                "confidence": "high",
            },
            ensure_ascii=False,
        ),
        input_tokens=4,
        output_tokens=2,
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=[_document(1)]),
        chat_model,
        provider_name="fake",
        model_name="fake-v1",
        reranker=_reranker(_FixedRerankModel([score])),
        relevance_threshold=0.44,
    )

    result = chain.invoke(PolicyRAGInput(request_id="gate", question="请假规定"))

    assert result.status == expected_status
    assert chat_model.calls == expected_calls
    if expected_status == "general_completed":
        assert result.warnings == ["campus_sources_unavailable"]
        assert result.usage.metered is True


def test_reranker_failure_preserves_degraded_mode_and_uses_fallback_generation():
    chat_model = _CountingChatModel(
        response_text="不应调用", input_tokens=1, output_tokens=1
    )
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=[_document(1)]),
        chat_model,
        provider_name="fake",
        model_name="fake-v1",
        reranker=_reranker(_FailingRerankModel()),
        relevance_threshold=0.44,
    )

    result = chain.invoke(PolicyRAGInput(request_id="degraded", question="问题"))

    assert result.status == "general_completed"
    assert result.degraded_modes == ["rerank"]
    assert chat_model.calls == 1


@pytest.mark.asyncio
async def test_async_cancellation_reaches_rerank_model():
    model = _BlockingAsyncRerankModel()
    task = asyncio.create_task(
        _reranker(model).acompress_documents([_document(1)], "问题")
    )
    await asyncio.wait_for(model.started.wait(), timeout=1)

    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.wait_for(model.cancelled.wait(), timeout=1)


@pytest.mark.asyncio
async def test_stream_reports_reranking_before_generation():
    chain = build_policy_rag_chain(
        FakePolicyRetriever(documents=[_document(1)]),
        FakePolicyChatModel(
            response_text=json.dumps(
                {
                    "answer": "有证据的回答。",
                    "current_rules": [{"statement": "政策证据 1", "citation_ids": ["R1"]}],
                    "historical_rules": [],
                    "warnings": [],
                    "citations": [{"reference_id": "R1", "quote": "政策证据 1"}],
                    "confidence": "high",
                },
                ensure_ascii=False,
            ),
            input_tokens=4,
            output_tokens=2,
        ),
        provider_name="fake",
        model_name="fake-v1",
        reranker=_reranker(_FixedRerankModel([0.9])),
        relevance_threshold=0.44,
    )

    events = [
        event
        async for event in astream_policy_events(
            chain, PolicyRAGInput(request_id="stream-rerank", question="问题")
        )
    ]
    event_types = [event.type for event in events]

    assert event_types.index("retrieving") < event_types.index("reranking")
    assert event_types.index("reranking") < event_types.index("generating")


def test_fastembed_download_permission_is_forwarded_explicitly(monkeypatch):
    from fastembed.rerank import cross_encoder

    calls: list[dict[str, object]] = []

    class _FakeCrossEncoder:
        def __init__(self, **kwargs):
            calls.append(kwargs)

        def rerank(self, query, documents, batch_size):
            del query, batch_size
            return [0.0] * len(documents)

    monkeypatch.setattr(cross_encoder, "TextCrossEncoder", _FakeCrossEncoder)
    FastEmbedCrossEncoderRerankModel(
        model_name="fixture",
        model_version="fixture-v1",
        allow_model_download=False,
    )
    FastEmbedCrossEncoderRerankModel(
        model_name="fixture",
        model_version="fixture-v1",
        allow_model_download=True,
    )

    assert calls[0]["local_files_only"] is True
    assert calls[1]["local_files_only"] is False


def test_t01_fixture_calibration_meets_gate_and_ranking_targets():
    data_directory = Path(__file__).parents[2] / "server" / "testdata" / "ai_eval"

    report = evaluate_reranker_fixture(data_directory, k=5)

    assert report["cases"] == 42
    assert report["relevance_threshold"] == 0.44
    assert report["gate_accuracy"] == 1.0
    assert report["answerable_recall"] == 1.0
    assert report["negative_rejection_rate"] == 1.0
    assert report["ranking_before"]["recall_at_k"] == pytest.approx(38 / 42)
    assert report["ranking_after"]["recall_at_k"] == 1.0
    assert report["ranking_after"]["mrr"] == 1.0
    assert report["v06_core_after"]["recall_at_k"] == 1.0
    assert report["v06_core_after"]["mrr"] == 1.0
    assert report["failures"] == []
