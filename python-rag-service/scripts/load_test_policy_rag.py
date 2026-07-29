from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence


REPORT_SCHEMA_VERSION = "t09-policy-rag-load/v1"
QUESTIONS = (
    "如何申请休学",
    "补考成绩怎么算",
    "课程重修有什么要求",
    "实验课补考没过怎么办",
    "完全无关的火星停车规定是什么",
)


@dataclass
class LoadSample:
    case_id: str
    success: bool = False
    status: str = "failed"
    error_class: str = ""
    timings_ms: dict[str, float] = field(default_factory=dict)


def percentile(values: Sequence[float], quantile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(max(0.0, float(value)) for value in values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * quantile) - 1))
    return round(ordered[index], 3)


def timing_summary(samples: Sequence[LoadSample], name: str) -> dict[str, int | float]:
    values = [sample.timings_ms[name] for sample in samples if name in sample.timings_ms]
    return {
        "count": len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "max": round(max(values), 3) if values else 0.0,
    }


def validate_target(base_url: str, allow_remote: bool) -> str:
    parsed = urllib.parse.urlsplit(base_url.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username:
        raise ValueError("base URL must be an HTTP(S) URL without user info")
    is_local = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
    if not is_local and not allow_remote:
        raise ValueError("remote load test requires --allow-remote")
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path.rstrip("/"), "", "")
    )


def _run_sample(
    *,
    base_url: str,
    token: str,
    question: str,
    case_id: str,
    timeout_seconds: float,
    read_delay_ms: int,
) -> LoadSample:
    sample = LoadSample(case_id=case_id)
    started_at = time.perf_counter()
    payload = json.dumps(
        {
            "request_id": str(uuid.uuid4()),
            "question": question,
            "history": [],
            "max_sources": 6,
        },
        ensure_ascii=False,
    ).encode("utf-8")
    request = urllib.request.Request(
        base_url + "/internal/rag/policy/query/stream",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "X-Internal-Service-Token": token,
        },
    )
    offsets: dict[str, float] = {}
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            offsets["response_headers"] = (time.perf_counter() - started_at) * 1_000
            for raw_line in response:
                received_at = (time.perf_counter() - started_at) * 1_000
                offsets.setdefault("first_byte", received_at)
                if read_delay_ms:
                    time.sleep(read_delay_ms / 1_000)
                line = raw_line.decode("utf-8", errors="strict").strip()
                if not line.startswith("data: "):
                    continue
                event = json.loads(line.removeprefix("data: "))
                event_type = str(event.get("type") or "")
                offsets.setdefault(event_type, received_at)
                if event_type == "failed":
                    sample.error_class = str(event.get("error_code") or "rag_failed")
                    sample.status = "failed"
                if event_type == "completed":
                    result = event.get("result") or {}
                    sample.status = str(result.get("status") or "unknown")
                    sample.success = sample.status in {
                        "completed",
                        "insufficient_sources",
                        "citation_rejected",
                    }
        finished_at = time.perf_counter()
        _derive_timings(sample, offsets, (finished_at - started_at) * 1_000)
        if not sample.success and not sample.error_class:
            sample.error_class = "incomplete_stream"
        return sample
    except (OSError, UnicodeError, json.JSONDecodeError, urllib.error.HTTPError) as exc:
        sample.error_class = type(exc).__name__
        sample.timings_ms["end_to_end"] = round(
            (time.perf_counter() - started_at) * 1_000, 3
        )
        return sample


def _derive_timings(sample: LoadSample, offsets: dict[str, float], total_ms: float) -> None:
    planning = offsets.get("planning", 0.0)
    retrieving = offsets.get("retrieving")
    reranking = offsets.get("reranking")
    generating = offsets.get("generating")
    token = offsets.get("token")
    completed = offsets.get("completed")
    if retrieving is not None:
        sample.timings_ms["query_planning"] = round(max(0.0, retrieving - planning), 3)
    if retrieving is not None and generating is not None:
        retrieval_end = reranking if reranking is not None else generating
        sample.timings_ms["retrieval"] = round(max(0.0, retrieval_end - retrieving), 3)
    if reranking is not None and generating is not None:
        sample.timings_ms["rerank"] = round(max(0.0, generating - reranking), 3)
    if token is not None:
        sample.timings_ms["first_token"] = round(token, 3)
    if completed is not None:
        sample.timings_ms["complete_answer"] = round(completed, 3)
        if generating is not None:
            sample.timings_ms["generation"] = round(max(0.0, completed - generating), 3)
    if "first_byte" in offsets:
        sample.timings_ms["first_byte"] = round(offsets["first_byte"], 3)
    sample.timings_ms["end_to_end"] = round(total_ms, 3)


async def run_load(
    *,
    base_url: str,
    token: str,
    requests: int,
    concurrency: int,
    timeout_seconds: float,
    read_delay_ms: int,
) -> tuple[list[LoadSample], float]:
    semaphore = asyncio.Semaphore(concurrency)

    async def one(index: int) -> LoadSample:
        async with semaphore:
            return await asyncio.to_thread(
                _run_sample,
                base_url=base_url,
                token=token,
                question=QUESTIONS[index % len(QUESTIONS)],
                case_id=f"case-{index % len(QUESTIONS)}",
                timeout_seconds=timeout_seconds,
                read_delay_ms=read_delay_ms,
            )

    started_at = time.perf_counter()
    samples = await asyncio.gather(*(one(index) for index in range(requests)))
    return samples, time.perf_counter() - started_at


def build_report(
    samples: Sequence[LoadSample],
    *,
    elapsed_seconds: float,
    concurrency: int,
    target_mode: str,
) -> dict[str, Any]:
    successes = sum(1 for sample in samples if sample.success)
    error_classes = Counter(sample.error_class for sample in samples if sample.error_class)
    timing_names = (
        "query_planning",
        "retrieval",
        "rerank",
        "first_byte",
        "first_token",
        "generation",
        "complete_answer",
        "end_to_end",
    )
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "target_mode": target_mode,
        "request_count": len(samples),
        "concurrency": concurrency,
        "throughput_rps": round(len(samples) / elapsed_seconds, 3) if elapsed_seconds else 0.0,
        "success_count": successes,
        "error_count": len(samples) - successes,
        "error_rate": round((len(samples) - successes) / len(samples), 6) if samples else 0.0,
        "statuses": dict(sorted(Counter(sample.status for sample in samples).items())),
        "error_classes": dict(sorted(error_classes.items())),
        "timings_ms": {name: timing_summary(samples, name) for name in timing_names},
        # 只保留固定用例编号，不写入问题、响应、Token 或服务地址。
        "cases": dict(sorted(Counter(sample.case_id for sample in samples).items())),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="T09 Policy RAG SSE 压测")
    parser.add_argument("--base-url", default="http://127.0.0.1:18001")
    parser.add_argument("--token", default=os.environ.get("RAG_SERVICE_TOKEN", ""))
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--timeout-seconds", type=float, default=90.0)
    parser.add_argument("--read-delay-ms", type=int, default=0)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--allow-remote", action="store_true")
    parser.add_argument("--execute", action="store_true", help="默认只打印计划，不发请求")
    parser.add_argument("--confirm", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if not 1 <= args.requests <= 1_000:
            raise ValueError("requests must be between 1 and 1000")
        if not 1 <= args.concurrency <= 32:
            raise ValueError("concurrency must be between 1 and 32")
        if not 5 <= args.timeout_seconds <= 300:
            raise ValueError("timeout must be between 5 and 300 seconds")
        if not 0 <= args.read_delay_ms <= 2_000:
            raise ValueError("read delay must be between 0 and 2000 ms")
        base_url = validate_target(args.base_url, args.allow_remote)
        plan = {
            "schema_version": REPORT_SCHEMA_VERSION,
            "requests": args.requests,
            "concurrency": args.concurrency,
            "target_mode": "local" if not args.allow_remote else "remote_authorized",
            "writes_performed": False,
        }
        if not args.execute:
            print(json.dumps(plan, ensure_ascii=False, indent=2))
            return 0
        required = f"LOAD:{args.requests}:{args.concurrency}"
        if args.confirm != required:
            raise ValueError(f"confirmation must be {required}")
        if not args.token.strip():
            raise ValueError("internal service token is required")
        if args.report is None:
            raise ValueError("report path is required")
        if args.report.exists():
            raise ValueError("report path already exists")
        samples, elapsed = asyncio.run(
            run_load(
                base_url=base_url,
                token=args.token,
                requests=args.requests,
                concurrency=args.concurrency,
                timeout_seconds=args.timeout_seconds,
                read_delay_ms=args.read_delay_ms,
            )
        )
        report = build_report(
            samples,
            elapsed_seconds=elapsed,
            concurrency=args.concurrency,
            target_mode=plan["target_mode"],
        )
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("x", encoding="utf-8", newline="\n") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if report["error_count"] == 0 else 1
    except (OSError, ValueError) as exc:
        print(f"load test blocked: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
