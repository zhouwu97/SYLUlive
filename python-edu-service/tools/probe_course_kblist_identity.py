#!/usr/bin/env python3
"""
SYLU course kbList identity probe.

Purpose:
- inventory every key in course schedule kbList items
- determine whether kbList exposes stable jxb_id/kch_id
- NEVER save password/cookie/CSRF
- write only sanitized structural output

Run from SYLUlive/python-edu-service directory:

    python tools/probe_course_kblist_identity.py

Use only your own SYLU account.
"""

from __future__ import annotations

import asyncio
import getpass
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any

# Adjust import path
sys.path.insert(0, str(Path(__file__).parent.parent))
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

import argparse
from services.crawler import EduCrawler, CookieLapseError, NetworkError
from config import COURSE_URL

OUTPUT_DIR = Path("tools/edu_probe/output/course_kblist_identity")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

SENSITIVE_KEYS = {
    "xh", "xh_id", "xsxh", "xsid", "sfzh",
    "xsxm", "xm_xs", "xsmc", "student_id", "user_id",
}
NAME_KEYS = {"xsxm", "xm_xs", "xsmc", "xm", "jsxm"}

IDENTITY_PATTERNS = (
    "jxb", "jxb_id", "jxbid", "jxbmc",
    "kch", "kch_id", "kcid", "kcdm",
    "jxrw", "jxbrw", "task",
    "jsgh", "zgh", "teacher", "teacherid",
    "xkkh", "section", "class",
)


def mask_value(value: str) -> str:
    value = str(value or "")
    if len(value) <= 4:
        return "****"
    return "*" * (len(value) - 4) + value[-4:]


def sanitize_value(key: str, value: Any) -> Any:
    lk = key.lower()
    if lk in SENSITIVE_KEYS:
        return mask_value(str(value))
    if lk in NAME_KEYS:
        return "***"
    if "cookie" in lk or "token" in lk or "csrf" in lk or "password" in lk:
        return "<redacted>"
    # Keep structural IDs for identity analysis
    return value


def inventory(items: list[dict[str, Any]]) -> dict[str, Any]:
    stats: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "present_count": 0,
            "non_empty_count": 0,
            "types": set(),
            "samples": [],
        }
    )

    for item in items:
        for key, value in item.items():
            entry = stats[key]
            entry["present_count"] += 1
            entry["types"].add(type(value).__name__)
            if value not in (None, "", [], {}):
                entry["non_empty_count"] += 1
                if len(entry["samples"]) < 3:
                    entry["samples"].append(sanitize_value(key, value))

    result = {}
    for key in sorted(stats):
        entry = stats[key]
        entry["types"] = sorted(entry["types"])
        result[key] = entry
    return result


def identity_candidates(field_inventory: dict[str, Any]) -> list[str]:
    out = []
    for key in field_inventory:
        lk = key.lower()
        if (
            lk.endswith("_id")
            or lk.endswith("id")
            or any(pattern in lk for pattern in IDENTITY_PATTERNS)
            or lk.endswith("dm")
            or lk.endswith("bh")
            or "code" in lk
        ):
            out.append(key)
    return sorted(set(out))


async def fetch_raw_kblist(
    crawler: EduCrawler,
    cookie: str,
    year: str,
    semester: int,
) -> dict[str, Any]:
    if not crawler.client:
        raise RuntimeError("crawler client not initialized")

    headers = {
        "Cookie": cookie,
        "User-Agent": crawler.client.headers.get("User-Agent", ""),
        "X-Requested-With": "XMLHttpRequest",
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
        "Referer": f"{COURSE_URL}/xskbcx_cxXsKb.html?gnmkdm=N2154",
        "Origin": COURSE_URL,
    }

    resp = await crawler.client.post(
        f"{COURSE_URL}/xskbcx_cxXsKb.html",
        params={"gnmkdm": "N2154"},
        data={"xnm": year, "xqm": str(semester), "kblx": "1"},
        headers=headers,
    )

    if resp.status_code in (302, 901):
        raise CookieLapseError("schedule endpoint redirected/session expired")
    if resp.status_code != 200:
        raise NetworkError(f"schedule endpoint HTTP {resp.status_code}")

    body = resp.text.strip()
    if "login_slogin" in body:
        raise CookieLapseError("schedule endpoint returned login page")

    try:
        payload = resp.json()
    except ValueError as exc:
        raise NetworkError("schedule endpoint returned non-JSON") from exc

    if not isinstance(payload, dict):
        raise NetworkError("schedule payload is not object")
    kb_list = payload.get("kbList")
    if not isinstance(kb_list, list):
        raise NetworkError("schedule payload missing list kbList")

    return payload


async def main() -> None:
    parser = argparse.ArgumentParser(description="SYLU course kbList identity probe")
    parser.add_argument("--student-id", help="Student ID")
    parser.add_argument("--password", help="Edu password")
    parser.add_argument("--year", help="Academic year code (e.g. 2024, 2025, 2026)")
    parser.add_argument("--semester", type=int, choices=[3, 12], help="Semester code (3 or 12)")
    args = parser.parse_args()

    print("SYLU course kbList identity probe")
    print("Use only your own account. Password/cookie are never written.")
    print()

    student_id = args.student_id or input("Student ID: ").strip()
    password = args.password or getpass.getpass("Edu password: ")
    year = args.year or input("Academic year code (e.g. 2025 or 2026): ").strip()
    semester = args.semester if args.semester is not None else int(input("Semester code (3 or 12): ").strip())

    if semester not in (3, 12):
        raise SystemExit("semester must be 3 or 12")

    print("\nLogging in...")
    async with EduCrawler() as crawler:
        cookie = await crawler.login(student_id, password)
        print("Fetching course schedule...")
        payload = await fetch_raw_kblist(crawler, cookie, year, semester)

    items = payload["kbList"]
    field_inventory = inventory(items)
    candidates = identity_candidates(field_inventory)

    # Local-only sanitized sample
    sanitized_items = []
    for item in items:
        sanitized_items.append({
            key: sanitize_value(key, value)
            for key, value in item.items()
        })

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    report = {
        "generated_at": datetime.now().isoformat(),
        "domain": "course_schedule",
        "endpoint": f"{COURSE_URL}/xskbcx_cxXsKb.html",
        "year": year,
        "semester": semester,
        "item_count": len(items),
        "field_inventory": field_inventory,
        "identity_candidates": candidates,
        "key_findings": {
            "has_jxb_id": "jxb_id" in field_inventory,
            "has_jxbid": "jxbid" in field_inventory,
            "has_kch_id": "kch_id" in field_inventory,
            "has_kch": "kch" in field_inventory,
        },
        "notes": [
            "This probe targets kbList (course schedule), not grade records.",
            "Presence of a candidate field does not prove semantic stability.",
            "Validate: same-section repeated meetings, different sections, repeated syncs.",
        ],
    }

    report_path = OUTPUT_DIR / f"kblist_identity_{year}_{semester}_{stamp}.json"
    sample_path = OUTPUT_DIR / f"kblist_sanitized_{year}_{semester}_{stamp}.json"

    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    sample_path.write_text(
        json.dumps(sanitized_items, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(f"\n=== RESULTS ===")
    print(f"kbList items: {len(items)}")
    print(f"Total fields: {len(field_inventory)}")
    print(f"\nKey findings:")
    print(f"  has jxb_id:  {report['key_findings']['has_jxb_id']}")
    print(f"  has jxbid:   {report['key_findings']['has_jxbid']}")
    print(f"  has kch_id:  {report['key_findings']['has_kch_id']}")
    print(f"  has kch:     {report['key_findings']['has_kch']}")
    print(f"\nIdentity candidates ({len(candidates)}):")
    for key in candidates:
        entry = field_inventory[key]
        print(f"  - {key:20s} present={entry['present_count']}/{len(items)} non_empty={entry['non_empty_count']}")
    print(f"\nReport:  {report_path}")
    print(f"Sample:  {sample_path}")
    print("\nDo NOT commit samples containing course/teacher/location data.")
    print("Copy key_findings to docs/references/sylu-course-identity.md")


if __name__ == "__main__":
    asyncio.run(main())
