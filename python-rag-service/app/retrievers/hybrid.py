from __future__ import annotations

import asyncio
import hashlib
import math
import re
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import Future, ThreadPoolExecutor, wait
from datetime import datetime, timezone
from typing import Any, Literal, Protocol

import jieba
import psycopg
from langchain_core.callbacks import (
    AsyncCallbackManagerForRetrieverRun,
    CallbackManagerForRetrieverRun,
)
from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings
from langchain_core.retrievers import BaseRetriever
from psycopg.rows import dict_row
from pydantic import BaseModel, ConfigDict, Field

from app.chains.query_planner import PolicyQueryPlanner
from app.schemas import PolicyQueryPlan


RetrievalChannel = Literal["exact", "fts", "vector", "trigram"]
RETRIEVAL_CHANNELS: tuple[RetrievalChannel, ...] = ("exact", "fts", "vector", "trigram")

RRF_BASE = 60.0
CHANNEL_WEIGHTS: Mapping[RetrievalChannel, float] = {
    "exact": 3.0,
    "fts": 2.0,
    "vector": 1.25,
    "trigram": 0.25,
}
DOCUMENT_PREFERENCE_UNIT = 0.002
CURRENT_SCHOOL_BONUS = 0.004
CURRENT_OFFICIAL_BONUS = 0.002
HISTORICAL_PENALTY = -0.002

_HISTORICAL_SQL = """(
    left(d.document_type, 11) = 'historical_'
    OR position('historical' IN lower(d.source_type)) > 0
)"""
_SELECT_COLUMNS = """
    c.id AS chunk_id, c.document_id, c.content, c.content_hash,
    d.title, d.document_type, d.source_type, d.department,
    d.source_uri, c.section_title, c.source_locator,
    d.effective_from, d.effective_to, d.published_at
"""
_VERSION_FILTER = f"""
    d.status = 'published' AND d.deleted_at IS NULL
    AND (d.effective_from IS NULL OR d.effective_from <= %(now)s)
    AND (
        (NOT {_HISTORICAL_SQL} AND (d.effective_to IS NULL OR d.effective_to >= %(now)s))
        OR (%(allow_historical)s AND {_HISTORICAL_SQL})
    )
"""
# search_tokens 在入库时已包含标题、文档类型、部门、章节和别名；该表达式与现有 GIN 索引一致。
_FTS_VECTOR_SQL = "to_tsvector('simple', c.search_tokens || ' ' || c.content)"

_EXACT_SQL = f"""
SELECT {_SELECT_COLUMNS}
FROM ai_knowledge_chunks c
JOIN ai_knowledge_documents d ON d.id = c.document_id
JOIN LATERAL (
    SELECT COALESCE(SUM(CASE
        WHEN position(lower(term) IN lower(concat_ws(' ', d.title, c.section_title,
            c.source_locator, c.metadata ->> 'aliases'))) > 0 THEN 4
        WHEN position(lower(term) IN lower(concat_ws(' ', d.document_type, d.department,
            c.search_tokens))) > 0 THEN 2
        WHEN position(lower(term) IN lower(c.content)) > 0 THEN 1
        ELSE 0 END), 0) AS exact_score
    FROM unnest(%(terms)s::text[]) AS terms(term)
    WHERE term <> ''
) term_match ON term_match.exact_score > 0
WHERE {_VERSION_FILTER}
ORDER BY term_match.exact_score DESC, c.id
LIMIT %(limit)s
"""

_FTS_SQL = f"""
WITH policy_query AS (
    SELECT websearch_to_tsquery('simple', %(fts_query)s) AS value
)
SELECT {_SELECT_COLUMNS},
       ts_rank_cd({_FTS_VECTOR_SQL}, policy_query.value) AS lexical_score
FROM ai_knowledge_chunks c
JOIN ai_knowledge_documents d ON d.id = c.document_id
CROSS JOIN policy_query
WHERE {_VERSION_FILTER}
  AND {_FTS_VECTOR_SQL} @@ policy_query.value
ORDER BY lexical_score DESC, c.id
LIMIT %(limit)s
"""

_TRIGRAM_SQL = f"""
SELECT {_SELECT_COLUMNS}
FROM ai_knowledge_chunks c
JOIN ai_knowledge_documents d ON d.id = c.document_id
WHERE {_VERSION_FILTER}
  AND similarity(concat_ws(' ', d.title, c.section_title, c.content), %(query)s) > 0.05
ORDER BY similarity(concat_ws(' ', d.title, c.section_title, c.content), %(query)s) DESC, c.id
LIMIT %(limit)s
"""


class PolicyRetrievalUnavailable(RuntimeError):
    """所有召回通道均不可用时返回的稳定错误，不携带底层连接信息。"""


class RetrievalCandidate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    chunk_id: int = Field(gt=0)
    document_id: int = Field(gt=0)
    content: str
    content_hash: str = ""
    title: str
    document_type: str = ""
    source_type: str = ""
    department: str = ""
    source_url: str = ""
    section_title: str = ""
    source_locator: str = ""
    effective_from: datetime | None = None
    effective_to: datetime | None = None
    published_at: datetime | None = None
    historical: bool = False


class RankedCandidate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    candidate: RetrievalCandidate
    rank: int = Field(gt=0)


class PolicySearchStore(Protocol):
    def check_read_only_permissions(self) -> None: ...

    def exact_search(
        self, plan: PolicyQueryPlan, limit: int
    ) -> list[RetrievalCandidate]: ...

    def fts_search(
        self, plan: PolicyQueryPlan, fts_query: str, limit: int
    ) -> list[RetrievalCandidate]: ...

    def vector_search(
        self,
        plan: PolicyQueryPlan,
        embedding: Sequence[float],
        model_version: str,
        dimensions: int,
        limit: int,
    ) -> list[RetrievalCandidate]: ...

    def trigram_search(
        self, plan: PolicyQueryPlan, limit: int
    ) -> list[RetrievalCandidate]: ...


class PostgresPolicySearchStore:
    """仅执行固定参数化 SELECT，并在每条连接上强制只读事务。"""

    def __init__(
        self,
        dsn: str,
        *,
        statement_timeout_seconds: float = 2.0,
        connect_timeout_seconds: int = 3,
    ) -> None:
        if not dsn.strip():
            raise ValueError("RAG_DATABASE_DSN is required")
        self._dsn = dsn.strip()
        self._statement_timeout_ms = max(100, int(statement_timeout_seconds * 1000))
        self._connect_timeout_seconds = max(1, min(connect_timeout_seconds, 10))

    def _connect(self) -> psycopg.Connection[dict[str, Any]]:
        connection = psycopg.connect(
            self._dsn,
            connect_timeout=self._connect_timeout_seconds,
            row_factory=dict_row,
        )
        connection.read_only = True
        return connection

    def check_read_only_permissions(self) -> None:
        tables = (
            "ai_knowledge_chunks",
            "ai_knowledge_documents",
            "ai_knowledge_chunk_embeddings",
        )
        with self._connect() as connection, connection.cursor() as cursor:
            for table in tables:
                cursor.execute(
                    """
                    SELECT
                        has_table_privilege(current_user, %s, 'SELECT') AS can_select,
                        has_table_privilege(current_user, %s, 'INSERT')
                            OR has_table_privilege(current_user, %s, 'UPDATE')
                            OR has_table_privilege(current_user, %s, 'DELETE')
                            OR has_table_privilege(current_user, %s, 'TRUNCATE') AS can_write
                    """,
                    (table, table, table, table, table),
                )
                row = cursor.fetchone()
                if not row or not row["can_select"] or row["can_write"]:
                    raise PermissionError(
                        "RAG database role is not least-privilege read-only"
                    )

    def _fetch(
        self, sql: str, parameters: Mapping[str, Any]
    ) -> list[RetrievalCandidate]:
        with self._connect() as connection, connection.cursor() as cursor:
            cursor.execute(
                "SELECT set_config('statement_timeout', %s, true)",
                (str(self._statement_timeout_ms),),
            )
            cursor.execute(sql, parameters)
            rows = cursor.fetchall()
        return [_candidate_from_row(row) for row in rows]

    def _parameters(self, plan: PolicyQueryPlan, limit: int) -> dict[str, Any]:
        return {
            "now": datetime.now(timezone.utc),
            "allow_historical": plan.allow_historical,
            "limit": max(1, min(limit, 100)),
        }

    def exact_search(
        self, plan: PolicyQueryPlan, limit: int
    ) -> list[RetrievalCandidate]:
        terms = _normalized_exact_terms(plan.exact_terms)
        if not terms:
            return []
        parameters = self._parameters(plan, limit)
        parameters["terms"] = terms
        return self._fetch(_EXACT_SQL, parameters)

    def fts_search(
        self, plan: PolicyQueryPlan, fts_query: str, limit: int
    ) -> list[RetrievalCandidate]:
        if not fts_query:
            return []
        parameters = self._parameters(plan, limit)
        parameters["fts_query"] = fts_query
        return self._fetch(_FTS_SQL, parameters)

    def vector_search(
        self,
        plan: PolicyQueryPlan,
        embedding: Sequence[float],
        model_version: str,
        dimensions: int,
        limit: int,
    ) -> list[RetrievalCandidate]:
        if (
            not embedding
            or dimensions <= 0
            or dimensions > 2_000
            or len(embedding) != dimensions
        ):
            raise ValueError("invalid query embedding dimensions")
        if not model_version.strip() or len(model_version) > 100:
            raise ValueError("invalid query embedding model version")
        vector_literal = _format_vector(embedding)
        if dimensions in (384, 1536):
            distance_sql = (
                f"ce.embedding::vector({dimensions}) <=> "
                f"%(embedding)s::vector({dimensions})"
            )
        else:
            distance_sql = "ce.embedding <=> %(embedding)s::vector"
        sql = f"""
        SELECT {_SELECT_COLUMNS}
        FROM ai_knowledge_chunks c
        JOIN ai_knowledge_chunk_embeddings ce ON ce.chunk_id = c.id
        JOIN ai_knowledge_documents d ON d.id = c.document_id
        WHERE {_VERSION_FILTER}
          AND ce.model_version = %(model_version)s
          AND ce.dimensions = %(dimensions)s
        ORDER BY {distance_sql}, c.id
        LIMIT %(limit)s
        """
        parameters = self._parameters(plan, limit)
        parameters.update(
            embedding=vector_literal,
            model_version=model_version.strip(),
            dimensions=dimensions,
        )
        return self._fetch(sql, parameters)

    def trigram_search(
        self, plan: PolicyQueryPlan, limit: int
    ) -> list[RetrievalCandidate]:
        parameters = self._parameters(plan, limit)
        parameters["query"] = plan.normalized_question
        return self._fetch(_TRIGRAM_SQL, parameters)


class UnavailablePolicySearchStore:
    """配置缺失时保持链结构不变，并以稳定错误失败关闭。"""

    def check_read_only_permissions(self) -> None:
        raise PolicyRetrievalUnavailable("policy retrieval unavailable")

    def __getattr__(self, name: str) -> Callable[..., list[RetrievalCandidate]]:
        if name.endswith("_search"):

            def unavailable(*args: Any, **kwargs: Any) -> list[RetrievalCandidate]:
                del args, kwargs
                raise PolicyRetrievalUnavailable("policy retrieval unavailable")

            return unavailable
        raise AttributeError(name)


class HybridPolicyRetriever(BaseRetriever):
    """LangChain 混合召回器：并行召回、加权融合并执行版本与多样性约束。"""

    planner: PolicyQueryPlanner = Field(default_factory=PolicyQueryPlanner)
    search_store: Any
    embeddings: Embeddings | None = None
    embedding_model_version: str = ""
    shadow_index_enabled: bool = True
    metrics_recorder: Any = Field(default=None, exclude=True)
    k: int = Field(default=6, ge=1, le=10)
    channel_limit: int = Field(default=30, ge=1, le=100)
    channel_timeout_seconds: float = Field(default=2.5, gt=0, le=30)

    def _get_relevant_documents(
        self,
        query: str,
        *,
        run_manager: CallbackManagerForRetrieverRun,
    ) -> list[Document]:
        plan = self.planner.invoke(
            query,
            config={
                "callbacks": run_manager.get_child(),
                "run_name": "policy_query_planner",
            },
        )
        channel_results, degraded, channel_metrics = self._run_channels_sync(plan)
        documents = fuse_policy_candidates(plan, channel_results, self.k, degraded)
        self._record_retrieval_metrics(query, channel_metrics, documents, degraded)
        _require_successful_channel(channel_results)
        return documents

    async def _aget_relevant_documents(
        self,
        query: str,
        *,
        run_manager: AsyncCallbackManagerForRetrieverRun,
    ) -> list[Document]:
        plan = await self.planner.ainvoke(
            query,
            config={
                "callbacks": run_manager.get_child(),
                "run_name": "policy_query_planner",
            },
        )
        channel_results, degraded, channel_metrics = await self._run_channels_async(plan)
        documents = fuse_policy_candidates(plan, channel_results, self.k, degraded)
        self._record_retrieval_metrics(query, channel_metrics, documents, degraded)
        _require_successful_channel(channel_results)
        return documents

    def _active_channels(self) -> tuple[RetrievalChannel, ...]:
        if self.shadow_index_enabled:
            return RETRIEVAL_CHANNELS
        return tuple(channel for channel in RETRIEVAL_CHANNELS if channel != "vector")

    def _record_retrieval_metrics(
        self,
        query: str,
        channel_metrics: Mapping[str, Mapping[str, Any]],
        documents: Sequence[Document],
        degraded_modes: Sequence[str],
    ) -> None:
        recorder = self.metrics_recorder
        if recorder is None:
            return
        recorder.record_retrieval_channels(
            query,
            channel_metrics,
            candidate_count=len(documents),
            degraded_modes=degraded_modes,
        )

    def _run_channel_sync(
        self, channel: RetrievalChannel, plan: PolicyQueryPlan
    ) -> list[RetrievalCandidate]:
        if channel == "exact":
            return self.search_store.exact_search(plan, self.channel_limit)
        if channel == "fts":
            return self.search_store.fts_search(
                plan, build_or_fts_query(plan), self.channel_limit
            )
        if channel == "trigram":
            return self.search_store.trigram_search(plan, self.channel_limit)
        if self.embeddings is None:
            raise PolicyRetrievalUnavailable("query embedding unavailable")
        embedding = self.embeddings.embed_query(plan.retrieval_query)
        return self.search_store.vector_search(
            plan,
            embedding,
            self.embedding_model_version,
            len(embedding),
            self.channel_limit,
        )

    async def _run_channel_async(
        self, channel: RetrievalChannel, plan: PolicyQueryPlan
    ) -> list[RetrievalCandidate]:
        if channel != "vector":
            return await asyncio.to_thread(self._run_channel_sync, channel, plan)
        if self.embeddings is None:
            raise PolicyRetrievalUnavailable("query embedding unavailable")
        embedding = await self.embeddings.aembed_query(plan.retrieval_query)
        return await asyncio.to_thread(
            self.search_store.vector_search,
            plan,
            embedding,
            self.embedding_model_version,
            len(embedding),
            self.channel_limit,
        )

    def _run_channels_sync(
        self, plan: PolicyQueryPlan
    ) -> tuple[
        dict[RetrievalChannel, list[RankedCandidate]],
        list[str],
        dict[str, dict[str, int | float | str]],
    ]:
        active_channels = self._active_channels()
        executor = ThreadPoolExecutor(
            max_workers=len(active_channels), thread_name_prefix="policy-retrieval"
        )
        started_at = {channel: time.perf_counter() for channel in active_channels}
        completed_at: dict[RetrievalChannel, float] = {}
        completion_lock = threading.Lock()
        futures: dict[Future[list[RetrievalCandidate]], RetrievalChannel] = {
            executor.submit(self._run_channel_sync, channel, plan): channel
            for channel in active_channels
        }
        for future, channel in futures.items():
            def record_completion(
                _: Future[list[RetrievalCandidate]],
                *,
                completed_channel: RetrievalChannel = channel,
            ) -> None:
                with completion_lock:
                    completed_at[completed_channel] = time.perf_counter()

            future.add_done_callback(record_completion)
        done, pending = wait(futures, timeout=self.channel_timeout_seconds)
        results: dict[RetrievalChannel, list[RankedCandidate]] = {}
        degraded: list[str] = []
        metrics: dict[str, dict[str, int | float | str]] = {}
        finished_at = time.perf_counter()
        for future, channel in futures.items():
            with completion_lock:
                channel_finished_at = completed_at.get(channel, finished_at)
            duration_ms = (channel_finished_at - started_at[channel]) * 1_000
            if future in pending:
                future.cancel()
                degraded.append(channel + "_timeout")
                metrics[channel] = {
                    "duration_ms": duration_ms,
                    "candidate_count": 0,
                    "outcome": "timeout",
                }
                continue
            try:
                results[channel] = _rank_candidates(future.result())
                metrics[channel] = {
                    "duration_ms": duration_ms,
                    "candidate_count": len(results[channel]),
                    "outcome": "ok",
                }
            except Exception:
                degraded.append(channel + "_failed")
                metrics[channel] = {
                    "duration_ms": duration_ms,
                    "candidate_count": 0,
                    "outcome": "failed",
                }
        if not self.shadow_index_enabled:
            degraded.append("shadow_index_disabled")
            metrics["vector"] = {
                "duration_ms": 0.0,
                "candidate_count": 0,
                "outcome": "disabled",
            }
        executor.shutdown(wait=False, cancel_futures=True)
        return results, degraded, metrics

    async def _run_channels_async(
        self, plan: PolicyQueryPlan
    ) -> tuple[
        dict[RetrievalChannel, list[RankedCandidate]],
        list[str],
        dict[str, dict[str, int | float | str]],
    ]:
        active_channels = self._active_channels()
        started_at = {channel: time.perf_counter() for channel in active_channels}
        completed_at: dict[RetrievalChannel, float] = {}
        tasks = {
            asyncio.create_task(self._run_channel_async(channel, plan)): channel
            for channel in active_channels
        }
        for task, channel in tasks.items():
            task.add_done_callback(
                lambda _, completed_channel=channel: completed_at.__setitem__(
                    completed_channel, time.perf_counter()
                )
            )
        try:
            done, pending = await asyncio.wait(
                tasks, timeout=self.channel_timeout_seconds
            )
        except asyncio.CancelledError:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            raise
        results: dict[RetrievalChannel, list[RankedCandidate]] = {}
        degraded: list[str] = []
        metrics: dict[str, dict[str, int | float | str]] = {}
        finished_at = time.perf_counter()
        for task, channel in tasks.items():
            channel_finished_at = completed_at.get(channel, finished_at)
            duration_ms = (channel_finished_at - started_at[channel]) * 1_000
            if task in pending:
                task.cancel()
                degraded.append(channel + "_timeout")
                metrics[channel] = {
                    "duration_ms": duration_ms,
                    "candidate_count": 0,
                    "outcome": "timeout",
                }
                continue
            try:
                results[channel] = _rank_candidates(task.result())
                metrics[channel] = {
                    "duration_ms": duration_ms,
                    "candidate_count": len(results[channel]),
                    "outcome": "ok",
                }
            except Exception:
                degraded.append(channel + "_failed")
                metrics[channel] = {
                    "duration_ms": duration_ms,
                    "candidate_count": 0,
                    "outcome": "failed",
                }
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        if not self.shadow_index_enabled:
            degraded.append("shadow_index_disabled")
            metrics["vector"] = {
                "duration_ms": 0.0,
                "candidate_count": 0,
                "outcome": "disabled",
            }
        return results, degraded, metrics


def _require_successful_channel(
    results: Mapping[RetrievalChannel, Sequence[RankedCandidate]],
) -> None:
    if not results:
        raise PolicyRetrievalUnavailable("policy retrieval unavailable")


def _rank_candidates(candidates: Sequence[RetrievalCandidate]) -> list[RankedCandidate]:
    return [
        RankedCandidate(candidate=item, rank=index + 1)
        for index, item in enumerate(candidates)
    ]


def _candidate_from_row(row: Mapping[str, Any]) -> RetrievalCandidate:
    document_type = str(row.get("document_type") or "")
    source_type = str(row.get("source_type") or "")
    historical = (
        document_type.lower().startswith("historical_")
        or "historical" in source_type.lower()
    )
    return RetrievalCandidate(
        chunk_id=int(row["chunk_id"]),
        document_id=int(row["document_id"]),
        content=str(row.get("content") or ""),
        content_hash=str(row.get("content_hash") or ""),
        title=str(row.get("title") or "未命名政策资料"),
        document_type=document_type,
        source_type=source_type,
        department=str(row.get("department") or ""),
        source_url=str(row.get("source_uri") or ""),
        section_title=str(row.get("section_title") or ""),
        source_locator=str(row.get("source_locator") or ""),
        effective_from=row.get("effective_from"),
        effective_to=row.get("effective_to"),
        published_at=row.get("published_at"),
        historical=historical,
    )


def _normalized_exact_terms(terms: Sequence[str]) -> list[str]:
    result: list[str] = []
    for term in terms:
        for part in term.replace("\n", " ").split():
            if part and part.casefold() not in {value.casefold() for value in result}:
                result.append(part)
    return result


def build_or_fts_query(plan: PolicyQueryPlan) -> str:
    candidates = [
        *jieba.lcut(plan.normalized_question),
        *plan.exact_terms,
        *plan.expanded_terms,
    ]
    clauses: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        candidate = re.sub(r'["\s]+', " ", candidate).strip()
        if not candidate or not any(character.isalnum() for character in candidate):
            continue
        key = candidate.casefold()
        if key in seen:
            continue
        seen.add(key)
        clauses.append(f'"{candidate}"')
    return " OR ".join(clauses)


def _format_vector(values: Sequence[float]) -> str:
    if not values or any(not math.isfinite(float(value)) for value in values):
        raise ValueError("invalid query embedding")
    return "[" + ",".join(format(float(value), ".7g") for value in values) + "]"


def _version_priority(candidate: RetrievalCandidate) -> float:
    if candidate.historical:
        return HISTORICAL_PENALTY
    bonus = 0.0
    if candidate.document_type.strip().lower().startswith("school_"):
        bonus += CURRENT_SCHOOL_BONUS
    if "official" in candidate.source_type.lower():
        bonus += CURRENT_OFFICIAL_BONUS
    return bonus


def _document_preference(plan: PolicyQueryPlan, document_type: str) -> float:
    try:
        index = plan.preferred_document_types.index(document_type)
    except ValueError:
        return 0.0
    return (len(plan.preferred_document_types) - index) * DOCUMENT_PREFERENCE_UNIT


def fuse_policy_candidates(
    plan: PolicyQueryPlan,
    channel_results: Mapping[RetrievalChannel, Sequence[RankedCandidate]],
    limit: int,
    degraded_modes: Sequence[str] = (),
) -> list[Document]:
    """使用加权 RRF 融合候选；该纯函数不依赖数据库或模型。"""

    if limit <= 0:
        return []
    lexical_ids = {
        item.candidate.chunk_id
        for channel in ("exact", "fts")
        for item in channel_results.get(channel, ())
    }
    enabled_channels = set(channel_results)
    if len(lexical_ids) >= limit:
        enabled_channels.discard("trigram")

    fused: dict[int, tuple[RetrievalCandidate, dict[str, float]]] = {}
    for channel in RETRIEVAL_CHANNELS:
        if channel not in enabled_channels:
            continue
        for ranked in channel_results.get(channel, ()):
            candidate = ranked.candidate
            if candidate.historical and not plan.allow_historical:
                continue
            current, scores = fused.get(
                candidate.chunk_id,
                (
                    candidate,
                    {
                        name: 0.0
                        for name in (
                            *RETRIEVAL_CHANNELS,
                            "document_preference",
                            "version_priority",
                        )
                    },
                ),
            )
            scores[channel] += CHANNEL_WEIGHTS[channel] / (RRF_BASE + ranked.rank)
            fused[candidate.chunk_id] = (current, scores)

    ranked_documents: list[Document] = []
    for candidate, scores in fused.values():
        scores["document_preference"] = _document_preference(
            plan, candidate.document_type
        )
        scores["version_priority"] = _version_priority(candidate)
        total = sum(scores.values())
        content_hash = (
            candidate.content_hash
            or hashlib.sha256(candidate.content.encode("utf-8")).hexdigest()
        )
        metadata = {
            "source_id": f"chunk:{candidate.chunk_id}",
            "chunk_id": candidate.chunk_id,
            "document_id": candidate.document_id,
            "title": candidate.title,
            "document_type": candidate.document_type,
            "source_type": candidate.source_type,
            "department": candidate.department,
            "source_url": candidate.source_url,
            "section_title": candidate.section_title,
            "source_locator": candidate.source_locator,
            "effective_from": _iso(candidate.effective_from),
            "effective_to": _iso(candidate.effective_to),
            "published_at": _iso(candidate.published_at),
            "historical": candidate.historical,
            "retrieval_score": total,
            "score_details": {**scores, "total": total},
            "query_plan": plan.audit_summary(),
            "degraded_modes": sorted(set(degraded_modes)),
            "retrieval_audit": {
                "content_hash": content_hash,
                "score": total,
                "version": "historical" if candidate.historical else "current",
                "locator": candidate.source_locator,
            },
        }
        ranked_documents.append(
            Document(page_content=candidate.content, metadata=metadata)
        )

    ranked_documents.sort(
        key=lambda document: (
            -float(document.metadata["retrieval_score"]),
            int(document.metadata["chunk_id"]),
        )
    )
    return diversify_policy_documents(ranked_documents, limit)


def diversify_policy_documents(
    documents: Sequence[Document], limit: int
) -> list[Document]:
    """同章节去重后，先覆盖不同文档，再允许每份文档补一个章节。"""

    if limit <= 0:
        return []
    deduplicated: list[Document] = []
    seen_sections: set[tuple[int, str]] = set()
    for document in documents:
        document_id = int(document.metadata["document_id"])
        section = str(document.metadata.get("section_title") or "").strip()
        if not section:
            section = f"chunk:{document.metadata['chunk_id']}"
        key = (document_id, section)
        if key in seen_sections:
            continue
        seen_sections.add(key)
        deduplicated.append(document)

    selected: list[Document] = []
    selected_chunks: set[int] = set()
    document_counts: dict[int, int] = {}

    def append(document: Document) -> None:
        selected.append(document)
        chunk_id = int(document.metadata["chunk_id"])
        document_id = int(document.metadata["document_id"])
        selected_chunks.add(chunk_id)
        document_counts[document_id] = document_counts.get(document_id, 0) + 1

    for document in deduplicated:
        document_id = int(document.metadata["document_id"])
        if document_counts.get(document_id, 0) == 0:
            append(document)
        if len(selected) == limit:
            return selected
    for document in deduplicated:
        chunk_id = int(document.metadata["chunk_id"])
        document_id = int(document.metadata["document_id"])
        if chunk_id not in selected_chunks and document_counts.get(document_id, 0) < 2:
            append(document)
        if len(selected) == limit:
            return selected
    for document in deduplicated:
        if int(document.metadata["chunk_id"]) not in selected_chunks:
            append(document)
        if len(selected) == limit:
            break
    return selected


def _iso(value: datetime | None) -> str:
    return value.isoformat() if value else ""
