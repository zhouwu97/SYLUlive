from __future__ import annotations

import hashlib
import hmac
import math
import secrets
import threading
import time
from collections import Counter, defaultdict, deque
from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence
from uuid import UUID

from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.documents import Document


OBSERVABILITY_SCHEMA_VERSION = "shenliyuan-rag-observability/v1"
_STAGE_NAMES = {
    "policy_context_rewrite": "context_rewrite",
    "policy_query_planning": "query_planning",
    "policy_generation": "generation",
    "citation_validation": "citation_validation",
}


@dataclass
class _RunSpan:
    name: str
    kind: str
    started_at: float
    parent_run_id: UUID | None
    root_run_id: UUID | None
    child_duration_ms: float = 0.0


@dataclass
class _Observation:
    query_hash: str
    started_at: float
    plan_type: str = "unknown"
    candidate_count: int = 0
    channel_metrics: dict[str, dict[str, int | float | str]] = field(default_factory=dict)
    stage_ms: dict[str, float] = field(default_factory=dict)
    gate_result: str = "unknown"
    status: str = "running"
    input_tokens: int = 0
    output_tokens: int = 0
    cache_hit_tokens: int = 0
    degraded_modes: list[str] = field(default_factory=list)


class _Histogram:
    def __init__(self, max_samples: int) -> None:
        self._samples: deque[float] = deque(maxlen=max_samples)
        self.count = 0
        self.total = 0.0
        self.maximum = 0.0

    def observe(self, value: float) -> None:
        normalized = max(0.0, float(value))
        self._samples.append(normalized)
        self.count += 1
        self.total += normalized
        self.maximum = max(self.maximum, normalized)

    def snapshot(self) -> dict[str, int | float]:
        values = sorted(self._samples)
        return {
            "count": self.count,
            "avg": round(self.total / self.count, 3) if self.count else 0.0,
            "p50": _percentile(values, 0.50),
            "p95": _percentile(values, 0.95),
            "p99": _percentile(values, 0.99),
            "max": round(self.maximum, 3),
        }


def _percentile(values: Sequence[float], quantile: float) -> float:
    if not values:
        return 0.0
    index = max(0, min(len(values) - 1, math.ceil(len(values) * quantile) - 1))
    return round(float(values[index]), 3)


class LocalRAGMetricsCallback(BaseCallbackHandler):
    """只提取结构化运行属性，绝不保存 Callback 收到的原始输入或输出。"""

    def __init__(self, registry: "LocalRAGMetrics") -> None:
        self._registry = registry

    def on_chain_start(
        self,
        serialized: dict[str, Any] | None,
        inputs: Any,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        del serialized, inputs, tags
        self._registry._start_run(
            run_id,
            parent_run_id,
            str(kwargs.get("name") or ""),
            metadata or {},
            kind="chain",
        )

    def on_chain_end(
        self,
        outputs: Any,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> None:
        del parent_run_id, kwargs
        self._registry._finish_run(run_id, outputs)

    def on_chain_error(
        self,
        error: BaseException,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> None:
        del error, parent_run_id, kwargs
        self._registry._fail_run(run_id)

    def on_retriever_start(
        self,
        serialized: dict[str, Any] | None,
        query: str,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        del serialized, query, tags
        self._registry._start_run(
            run_id,
            parent_run_id,
            str(kwargs.get("name") or "policy_retriever"),
            metadata or {},
            kind="retriever",
        )

    def on_retriever_end(
        self,
        documents: Sequence[Document],
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> None:
        del parent_run_id, kwargs
        self._registry._finish_run(run_id, list(documents))

    def on_retriever_error(
        self,
        error: BaseException,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> None:
        del error, parent_run_id, kwargs
        self._registry._fail_run(run_id)


class LocalRAGMetrics:
    """有界进程内指标；快照只能通过内部鉴权接口读取。"""

    def __init__(
        self,
        *,
        chain_name: str,
        chain_version: str,
        hash_secret: str | bytes | None = None,
        max_samples: int = 2_000,
        recent_limit: int = 100,
    ) -> None:
        secret = hash_secret or secrets.token_bytes(32)
        self._hash_secret = secret.encode("utf-8") if isinstance(secret, str) else secret
        self.chain_name = chain_name
        self.chain_version = chain_version
        self.callback = LocalRAGMetricsCallback(self)
        self._lock = threading.RLock()
        self._runs: dict[UUID, _RunSpan] = {}
        self._active: dict[UUID, _Observation] = {}
        self._recent: deque[dict[str, Any]] = deque(maxlen=max(1, recent_limit))
        self._requests: Counter[str] = Counter()
        self._plans: Counter[str] = Counter()
        self._gates: Counter[str] = Counter()
        self._degraded_modes: Counter[str] = Counter()
        self._stage_errors: Counter[str] = Counter()
        self._stage_histograms = defaultdict(lambda: _Histogram(max_samples))
        self._channel_histograms = defaultdict(lambda: _Histogram(max_samples))
        self._channel_candidates: Counter[str] = Counter()
        self._channel_outcomes: Counter[str] = Counter()
        self._usage = Counter()

    def hash_query(self, query: str) -> str:
        digest = hmac.new(
            self._hash_secret,
            query.strip().encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        return digest[:24]

    def callback_config(self, query: str) -> dict[str, Any]:
        return {
            "callbacks": [self.callback],
            "metadata": {"query_hash": self.hash_query(query)},
        }

    def record_retrieval_channels(
        self,
        query: str,
        channel_metrics: Mapping[str, Mapping[str, Any]],
        *,
        candidate_count: int,
        degraded_modes: Sequence[str],
    ) -> None:
        query_hash = self.hash_query(query)
        sanitized: dict[str, dict[str, int | float | str]] = {}
        with self._lock:
            for channel, raw in channel_metrics.items():
                duration_ms = max(0.0, float(raw.get("duration_ms", 0.0)))
                count = max(0, int(raw.get("candidate_count", 0)))
                outcome = str(raw.get("outcome") or "unknown")
                sanitized[channel] = {
                    "duration_ms": round(duration_ms, 3),
                    "candidate_count": count,
                    "outcome": outcome,
                }
                self._channel_histograms[channel].observe(duration_ms)
                self._channel_candidates[channel] += count
                self._channel_outcomes[f"{channel}:{outcome}"] += 1
            for observation in self._active.values():
                if observation.query_hash != query_hash:
                    continue
                observation.channel_metrics = sanitized
                observation.candidate_count = max(0, int(candidate_count))
                observation.degraded_modes = sorted(
                    {str(value) for value in degraded_modes if str(value)}
                )

    def _start_run(
        self,
        run_id: UUID,
        parent_run_id: UUID | None,
        name: str,
        metadata: Mapping[str, Any],
        *,
        kind: str,
    ) -> None:
        now = time.perf_counter()
        with self._lock:
            parent = self._runs.get(parent_run_id) if parent_run_id else None
            root_run_id = parent.root_run_id if parent else None
            if name == self.chain_name:
                root_run_id = run_id
            self._runs[run_id] = _RunSpan(
                name=name,
                kind=kind,
                started_at=now,
                parent_run_id=parent_run_id,
                root_run_id=root_run_id,
            )
            if name == self.chain_name:
                query_hash = str(metadata.get("query_hash") or "missing")
                self._active[run_id] = _Observation(query_hash=query_hash, started_at=now)
                self._requests["started"] += 1

    def _finish_run(self, run_id: UUID, outputs: Any) -> None:
        now = time.perf_counter()
        with self._lock:
            span = self._runs.pop(run_id, None)
            if span is None:
                return
            duration_ms = (now - span.started_at) * 1_000
            parent = self._runs.get(span.parent_run_id) if span.parent_run_id else None
            if parent is not None:
                parent.child_duration_ms += duration_ms
            observation = self._active.get(span.root_run_id) if span.root_run_id else None
            stage = self._stage_for_span(span)
            if stage:
                # ContextualCompressionRetriever 的外层 span 同时包含基础召回；
                # 扣除直接子 span 后才是可用于发布门禁的重排耗时。
                stage_duration_ms = (
                    max(0.0, duration_ms - span.child_duration_ms)
                    if stage == "rerank"
                    else duration_ms
                )
                self._stage_histograms[stage].observe(stage_duration_ms)
                if observation is not None:
                    observation.stage_ms[stage] = round(stage_duration_ms, 3)
            if observation is not None:
                self._extract_stage_result(span.name, outputs, observation)
            if span.name == self.chain_name:
                self._stage_histograms["end_to_end"].observe(duration_ms)
                self._finalize_observation(run_id, outputs, duration_ms)

    def _fail_run(self, run_id: UUID) -> None:
        now = time.perf_counter()
        with self._lock:
            span = self._runs.pop(run_id, None)
            if span is None:
                return
            stage = self._stage_for_span(span) or span.name or "unknown"
            self._stage_errors[stage] += 1
            if span.name == self.chain_name:
                duration_ms = (now - span.started_at) * 1_000
                observation = self._active.pop(run_id, None)
                self._requests["failed"] += 1
                if observation is not None:
                    observation.status = "failed"
                    observation.stage_ms["end_to_end"] = round(duration_ms, 3)
                    self._recent.append(self._observation_dict(observation))

    @staticmethod
    def _stage_for_span(span: _RunSpan) -> str:
        if span.kind == "retriever":
            return "rerank" if span.name == "policy_reranking" else "retrieval"
        return _STAGE_NAMES.get(span.name, "")

    def _extract_stage_result(
        self,
        name: str,
        outputs: Any,
        observation: _Observation,
    ) -> None:
        if name == "policy_query_planning" and isinstance(outputs, Mapping):
            plan = outputs.get("query_plan")
            intent = getattr(plan, "intent", None)
            if intent is None and isinstance(plan, Mapping):
                intent = plan.get("intent")
            observation.plan_type = str(intent or "unknown")
            self._plans[observation.plan_type] += 1
        if name in {"policy_retrieval", "policy_reranking", "policy_retriever"}:
            documents = outputs.get("documents", []) if isinstance(outputs, Mapping) else outputs
            if isinstance(documents, Sequence) and not isinstance(documents, (str, bytes)):
                observation.candidate_count = len(documents)
        if name == "evidence_gate":
            status = _field(outputs, "status", "unknown")
            gate_result = "passed" if status in {"completed", "citation_rejected"} else "blocked"
            observation.gate_result = gate_result
            self._gates[gate_result] += 1

    def _finalize_observation(self, run_id: UUID, outputs: Any, duration_ms: float) -> None:
        observation = self._active.pop(run_id, None)
        if observation is None:
            return
        status = str(_field(outputs, "status", "unknown"))
        usage = _field(outputs, "usage", {})
        observation.status = status
        observation.input_tokens = max(0, int(_field(usage, "input_tokens", 0)))
        observation.output_tokens = max(0, int(_field(usage, "output_tokens", 0)))
        observation.cache_hit_tokens = max(0, int(_field(usage, "cache_hit_tokens", 0)))
        degraded = _field(outputs, "degraded_modes", [])
        observation.degraded_modes = sorted(
            {str(value) for value in degraded if str(value)}
        ) if isinstance(degraded, Sequence) and not isinstance(degraded, (str, bytes)) else []
        observation.stage_ms["end_to_end"] = round(duration_ms, 3)
        self._requests[status] += 1
        self._usage["input_tokens"] += observation.input_tokens
        self._usage["output_tokens"] += observation.output_tokens
        self._usage["cache_hit_tokens"] += observation.cache_hit_tokens
        for mode in observation.degraded_modes:
            self._degraded_modes[mode] += 1
        self._recent.append(self._observation_dict(observation))

    def _observation_dict(self, observation: _Observation) -> dict[str, Any]:
        return {
            "chain_name": self.chain_name,
            "chain_version": self.chain_version,
            "query_hash": observation.query_hash,
            "plan_type": observation.plan_type,
            "candidate_count": observation.candidate_count,
            "channel_metrics": observation.channel_metrics,
            "stage_ms": observation.stage_ms,
            "gate_result": observation.gate_result,
            "status": observation.status,
            "usage": {
                "input_tokens": observation.input_tokens,
                "output_tokens": observation.output_tokens,
                "cache_hit_tokens": observation.cache_hit_tokens,
            },
            "degraded_modes": observation.degraded_modes,
        }

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            channel_names = sorted(self._channel_histograms)
            outcomes: dict[str, dict[str, int]] = defaultdict(dict)
            for key, count in self._channel_outcomes.items():
                channel, outcome = key.split(":", 1)
                outcomes[channel][outcome] = count
            return {
                "schema_version": OBSERVABILITY_SCHEMA_VERSION,
                "chain_name": self.chain_name,
                "chain_version": self.chain_version,
                "export": {"mode": "local_only", "langsmith_enabled": False},
                "requests": dict(sorted(self._requests.items())),
                "plans": dict(sorted(self._plans.items())),
                "gates": dict(sorted(self._gates.items())),
                "usage": dict(sorted(self._usage.items())),
                "degraded_modes": dict(sorted(self._degraded_modes.items())),
                "stages_ms": {
                    name: histogram.snapshot()
                    for name, histogram in sorted(self._stage_histograms.items())
                },
                "stage_errors": dict(sorted(self._stage_errors.items())),
                "retrieval_channels": {
                    name: {
                        "duration_ms": self._channel_histograms[name].snapshot(),
                        "candidate_total": self._channel_candidates[name],
                        "outcomes": dict(sorted(outcomes[name].items())),
                    }
                    for name in channel_names
                },
                "recent": list(self._recent),
            }


def _field(value: Any, name: str, default: Any) -> Any:
    if isinstance(value, Mapping):
        return value.get(name, default)
    return getattr(value, name, default)
