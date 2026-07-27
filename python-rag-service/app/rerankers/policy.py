from __future__ import annotations

import asyncio
import hashlib
import math
import threading
from collections.abc import Awaitable, Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Protocol
from weakref import finalize

from langchain_core.callbacks.base import Callbacks
from langchain_core.documents import Document
from langchain_core.documents.compressor import BaseDocumentCompressor
from pydantic import ConfigDict, Field, PrivateAttr


POLICY_DOCUMENT_TYPE_LABEL_VERSION = "policy-document-type-zh-v1"
POLICY_DOCUMENT_TYPE_LABELS = {
    "school_competition_course_grade_reward_policy": "课外活动竞赛课程成绩奖励政策",
    "school_undergraduate_retake_policy": "本科生课程重修政策",
    "school_undergraduate_major_transfer_policy": "本科生转专业政策",
    "school_exam_misconduct_policy": "考试违纪作弊处理政策",
    "school_undergraduate_status_policy": "本科生学籍管理政策",
    "historical_school_second_exam_policy": "历史二次考试补考政策",
    "school_policy_reasoning_card": "校内政策推理卡",
    "school_exam_policy": "本科生课程考核政策",
    "school_test_policy": "校内测试政策",
}


def policy_document_type_label(document_type: str) -> str:
    """返回适合中文 CrossEncoder 的文档类型标签，未知类型保留原值。"""

    normalized = document_type.strip()
    return POLICY_DOCUMENT_TYPE_LABELS.get(normalized, normalized)


class PolicyRerankModel(Protocol):
    model_name: str
    model_version: str

    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]: ...


class PolicyRerankUnavailable(RuntimeError):
    """重排模型不可用时使用的稳定错误，不携带下载路径或底层响应。"""


class UnavailablePolicyRerankModel:
    """模型初始化失败后保留压缩器链路，由压缩器执行确定性降级。"""

    model_name = "unavailable"
    model_version = "unavailable"

    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]:
        del query, documents
        raise PolicyRerankUnavailable("policy reranker unavailable")


class FastEmbedCrossEncoderRerankModel:
    """将 FastEmbed CrossEncoder 的原始 logit 归一化为 0 到 1 的相关性分数。"""

    def __init__(
        self,
        *,
        model_name: str,
        model_version: str,
        allow_model_download: bool,
        cache_dir: str | None = None,
        batch_size: int = 16,
        threads: int | None = None,
        max_concurrency: int = 1,
    ) -> None:
        # 延迟导入可确保功能关闭时不会初始化模型运行时或触发下载检查。
        from fastembed.rerank.cross_encoder import TextCrossEncoder

        self.model_name = model_name
        self.model_version = model_version
        self.batch_size = max(1, min(batch_size, 64))
        self._semaphore = threading.BoundedSemaphore(max(1, min(max_concurrency, 4)))
        self._model = TextCrossEncoder(
            model_name=model_name,
            cache_dir=cache_dir or None,
            threads=threads,
            local_files_only=not allow_model_download,
        )

    def score(self, query: str, documents: Sequence[str]) -> Sequence[float]:
        with self._semaphore:
            logits = list(
                self._model.rerank(query, documents, batch_size=self.batch_size)
            )
        return [_sigmoid(float(value)) for value in logits]


class PolicyReranker(BaseDocumentCompressor):
    """LangChain 文档压缩器：稳定去重、重排并写入可审计分数。"""

    model_config = ConfigDict(arbitrary_types_allowed=True)

    rerank_model: Any
    model_name: str = Field(min_length=1, max_length=200)
    model_version: str = Field(min_length=1, max_length=200)
    top_n: int = Field(default=6, ge=1, le=20)
    max_candidates: int = Field(default=20, ge=1, le=20)
    timeout_seconds: float = Field(default=5.0, gt=0, le=30)
    max_document_chars: int = Field(default=4_000, ge=128, le=8_000)
    max_concurrency: int = Field(default=1, ge=1, le=4)
    query_transform: Callable[[str], str] | None = Field(default=None, exclude=True)
    query_strategy: str = Field(default="raw-query-v1", min_length=1, max_length=100)
    max_query_chars: int = Field(default=1_000, ge=64, le=2_000)
    _executor: ThreadPoolExecutor = PrivateAttr()
    _executor_finalizer: Any = PrivateAttr(default=None)

    def model_post_init(self, __context: Any) -> None:
        del __context
        # 实例级线程池限制超时后仍在运行的同步推理数量，避免按请求创建线程导致资源无界增长。
        executor = ThreadPoolExecutor(
            max_workers=self.max_concurrency,
            thread_name_prefix="policy-rerank",
        )
        self._executor = executor
        self._executor_finalizer = finalize(
            self,
            executor.shutdown,
            wait=False,
            cancel_futures=True,
        )

    def compress_documents(
        self,
        documents: Sequence[Document],
        query: str,
        callbacks: Callbacks | None = None,
    ) -> Sequence[Document]:
        del callbacks
        candidates = self._prepare_candidates(documents)
        if not candidates:
            return []
        texts = [self._model_text(document) for document in candidates]
        future = None
        try:
            model_query = self._model_query(query)
            future = self._executor.submit(self.rerank_model.score, model_query, texts)
            scores = future.result(timeout=self.timeout_seconds)
            return self._rank(candidates, scores)
        except Exception:
            if future is not None:
                future.cancel()
            return self._fallback(candidates)

    async def acompress_documents(
        self,
        documents: Sequence[Document],
        query: str,
        callbacks: Callbacks | None = None,
    ) -> Sequence[Document]:
        del callbacks
        candidates = self._prepare_candidates(documents)
        if not candidates:
            return []
        texts = [self._model_text(document) for document in candidates]
        try:
            model_query = self._model_query(query)
            scores = await asyncio.wait_for(
                self._score_async(model_query, texts), timeout=self.timeout_seconds
            )
            return self._rank(candidates, scores)
        except asyncio.CancelledError:
            raise
        except Exception:
            return self._fallback(candidates)

    async def _score_async(
        self, query: str, documents: Sequence[str]
    ) -> Sequence[float]:
        async_score: Callable[
            [str, Sequence[str]], Awaitable[Sequence[float]]
        ] | None = getattr(self.rerank_model, "ascore", None)
        if async_score is not None:
            return await async_score(query, documents)
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor,
            self.rerank_model.score,
            query,
            documents,
        )

    def _prepare_candidates(self, documents: Sequence[Document]) -> list[Document]:
        result: list[Document] = []
        seen: set[str] = set()
        for document in documents:
            key = _document_key(document)
            if key in seen:
                continue
            seen.add(key)
            result.append(document)
            if len(result) >= self.max_candidates:
                break
        return result

    def _model_query(self, query: str) -> str:
        transformed = self.query_transform(query) if self.query_transform else query
        normalized = str(transformed).strip()
        if not normalized:
            raise ValueError("empty reranker query")
        return normalized[: self.max_query_chars]

    def _model_text(self, document: Document) -> str:
        metadata = document.metadata
        document_type = str(metadata.get("document_type") or "")
        document_type_label = str(metadata.get("document_type_label") or "").strip()
        if not document_type_label:
            document_type_label = policy_document_type_label(document_type)
        prefix = "\n".join(
            value
            for value in (
                str(metadata.get("title") or "").strip(),
                document_type_label,
                str(metadata.get("section_title") or "").strip(),
            )
            if value
        )
        text = f"{prefix}\n{document.page_content}" if prefix else document.page_content
        return text[: self.max_document_chars]

    def _rank(
        self, documents: Sequence[Document], scores: Sequence[float]
    ) -> list[Document]:
        normalized = [float(value) for value in scores]
        if len(normalized) != len(documents) or any(
            not math.isfinite(value) or value < 0 or value > 1 for value in normalized
        ):
            return self._fallback(documents)

        ranked = sorted(
            enumerate(zip(documents, normalized, strict=True)),
            key=lambda item: (-item[1][1], item[0]),
        )
        result: list[Document] = []
        for rank, (original_index, (document, score)) in enumerate(
            ranked[: self.top_n], start=1
        ):
            copied = document.model_copy(deep=True)
            copied.metadata.update(
                {
                    "rerank_applied": True,
                    "rerank_score": score,
                    "rerank_rank": rank,
                    "rerank_original_rank": original_index + 1,
                    "rerank_model": self.model_name,
                    "rerank_model_version": self.model_version,
                    "rerank_query_strategy": self.query_strategy,
                    "rerank_document_type_label_version": POLICY_DOCUMENT_TYPE_LABEL_VERSION,
                }
            )
            result.append(copied)
        return result

    def _fallback(self, documents: Sequence[Document]) -> list[Document]:
        result: list[Document] = []
        for original_index, document in enumerate(documents[: self.top_n], start=1):
            copied = document.model_copy(deep=True)
            degraded = copied.metadata.get("degraded_modes", [])
            modes = {str(value) for value in degraded if str(value)} if isinstance(degraded, list) else set()
            modes.add("rerank")
            copied.metadata.update(
                {
                    "degraded_modes": sorted(modes),
                    "rerank_applied": False,
                    "rerank_original_rank": original_index,
                    "rerank_model": self.model_name,
                    "rerank_model_version": self.model_version,
                    "rerank_query_strategy": self.query_strategy,
                    "rerank_document_type_label_version": POLICY_DOCUMENT_TYPE_LABEL_VERSION,
                }
            )
            copied.metadata.pop("rerank_score", None)
            copied.metadata.pop("rerank_rank", None)
            result.append(copied)
        return result


def _document_key(document: Document) -> str:
    chunk_id = document.metadata.get("chunk_id")
    if chunk_id not in (None, "", 0, "0"):
        return f"chunk:{chunk_id}"
    content_hash = hashlib.sha256(document.page_content.encode("utf-8")).hexdigest()
    return f"content:{content_hash}"


def _sigmoid(value: float) -> float:
    if value >= 0:
        factor = math.exp(-value)
        return 1.0 / (1.0 + factor)
    factor = math.exp(value)
    return factor / (1.0 + factor)
