import json

import pytest

from scripts.load_test_policy_rag import (
    LoadSample,
    build_report,
    percentile,
    validate_target,
)


def test_percentile_and_report_include_required_t09_latency_dimensions():
    assert percentile([1, 2, 3, 4], 0.50) == 2
    samples = [
        LoadSample(
            case_id="case-0",
            success=True,
            status="completed",
            timings_ms={
                "query_planning": value,
                "retrieval": value + 1,
                "rerank": value + 2,
                "first_token": value + 3,
                "complete_answer": value + 4,
                "end_to_end": value + 5,
            },
        )
        for value in (10.0, 20.0, 30.0)
    ]

    report = build_report(samples, elapsed_seconds=1.5, concurrency=2, target_mode="local")

    assert report["throughput_rps"] == 2.0
    assert report["error_rate"] == 0.0
    for name in (
        "query_planning",
        "retrieval",
        "rerank",
        "first_token",
        "complete_answer",
        "end_to_end",
    ):
        assert report["timings_ms"][name]["p50"] > 0
        assert "p95" in report["timings_ms"][name]
        assert "p99" in report["timings_ms"][name]
    assert "question" not in json.dumps(report)


def test_remote_load_requires_explicit_authorization():
    assert validate_target("http://127.0.0.1:18001", False).endswith(":18001")
    with pytest.raises(ValueError, match="allow-remote"):
        validate_target("https://rag.example.test", False)
    assert validate_target("https://rag.example.test", True) == "https://rag.example.test"
