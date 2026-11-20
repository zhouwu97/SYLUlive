"""Local, opt-in undergraduate read benchmark; credentials and payloads stay in memory."""
from __future__ import annotations

import argparse
import asyncio
from contextlib import redirect_stdout
import getpass
import io
import json
import logging
import statistics
import sys
import time
from pathlib import Path
from typing import Any


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    position = (len(ordered) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower), 2)


async def benchmark(credentials: dict[str, str], *, year: str, semester: int, samples: int) -> dict[str, Any]:
    # Import only after the explicit live gate; no service, database or HTTP listener is started.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python-edu-service"))

    report: dict[str, Any] = {
        "schema": "academic-access-performance/v1", "mode": "live",
        "provider": "undergraduate", "authenticated": False,
        "request_metrics": [], "operations": [], "samples": samples,
    }
    stage = "login"
    requests = 0

    async def before(request):
        nonlocal requests
        if request.url.scheme != "https" or request.url.host != "jxw.sylu.edu.cn":
            raise RuntimeError("unexpected_school_origin")
        requests += 1
        if requests > 64:
            raise RuntimeError("request_budget_exceeded")
        request.extensions["benchmark_started"] = time.perf_counter()

    async def after(response):
        started = response.request.extensions.get("benchmark_started", time.perf_counter())
        report["request_metrics"].append({
            "stage": stage, "status": response.status_code,
            "ttfb_ms": round((time.perf_counter() - started) * 1000, 2),
        })

    previous_logging_level = logging.root.manager.disable
    logging.disable(logging.CRITICAL)
    try:
        from services.crawler import EduCrawler
        async with EduCrawler(timeout=25.0) as crawler:
            assert crawler.client is not None
            crawler.client.event_hooks = {"request": [before], "response": [after]}
            cookie = await crawler.login(credentials["student_id"], credentials["password"])
            report["authenticated"] = True
            try:
                for sample in range(samples):
                    for dataset in ("courses", "grades"):
                        stage = dataset
                        started = time.perf_counter()
                        operation: dict[str, Any] = {"dataset": dataset, "sample": sample + 1}
                        count_before = requests
                        try:
                            before_identity = await crawler.get_student_info(cookie, credentials["student_id"])
                            if before_identity.school_verified_student_id != credentials["student_id"]:
                                raise RuntimeError("identity_changed")
                            if dataset == "courses":
                                data = await crawler.fetch_courses(cookie, year, semester)
                            else:
                                data = await crawler.fetch_grades(cookie, year, semester)
                            after_identity = await crawler.get_student_info(cookie, credentials["student_id"])
                            if after_identity.school_verified_student_id != credentials["student_id"]:
                                raise RuntimeError("identity_changed")
                            operation["success"] = isinstance(data, list)
                            del data
                        except Exception as error:
                            operation.update(success=False, error_code=getattr(error, "code", type(error).__name__))
                        operation.update(elapsed_ms=round((time.perf_counter() - started) * 1000, 2), requests=requests - count_before)
                        report["operations"].append(operation)
                        if not operation["success"]:
                            report["passed"] = False
                            return report
            finally:
                crawler.client.cookies.clear()
                cookie = ""
    except Exception as error:
        report.update(passed=False, error_code=getattr(error, "code", type(error).__name__))
        return report
    finally:
        credentials.clear()
        logging.disable(previous_logging_level)
    for dataset in ("courses", "grades"):
        values = [v["elapsed_ms"] for v in report["operations"] if v["dataset"] == dataset]
        report[dataset] = {"p50_ms": round(statistics.median(values), 2), "p95_ms": percentile(values, .95)}
    report["passed"] = True
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--credentials-stdin", action="store_true", help="Read credentials as JSON from a private stdin pipe, never command arguments")
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--year", required=True)
    parser.add_argument("--semester", type=int, choices=[1, 2, 3], default=1)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if not arguments.live:
        parser.error("explicit --live is required")
    if not 1 <= arguments.samples <= 5 or len(arguments.year) != 4 or not arguments.year.isdigit():
        parser.error("invalid sample count or academic year")
    if arguments.credentials_stdin:
        credentials = json.load(sys.stdin)
    else:
        credentials = {"student_id": getpass.getpass("School account: "), "password": getpass.getpass("School password: ")}
    if not isinstance(credentials, dict) or not all(isinstance(credentials.get(key), str) and credentials[key] for key in ("student_id", "password")):
        parser.error("invalid credentials input")
    # Legacy crawler progress output must never become a durable benchmark log.
    with io.StringIO() as transient_output, redirect_stdout(transient_output):
        result = asyncio.run(benchmark(credentials, year=arguments.year, semester=arguments.semester, samples=arguments.samples))
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": result.get("passed"), "authenticated": result["authenticated"], "operations": len(result["operations"]), "error_code": result.get("error_code")}, ensure_ascii=False))
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
