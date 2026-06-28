"""
Supplementary probe — answers two open questions before the report:

A. Does empty xnm/xqm (or omitting them) return ALL grades in one shot?
B. Does the production queryModel.showCount=50 truncate? Are top-level
   pagination fields (totalResult/totalPage/currentPage/showCount)
   present, and can we page through?

Reads credentials from .credentials.json (gitignored). Does NOT auto-delete.

Usage:
    python tools/edu_probe/run_probe_pagination.py
"""
import asyncio
import json
import sys
from pathlib import Path

PROBE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROBE_DIR))

from crawler_probe import ProbeCrawler  # noqa: E402

CREDS = PROBE_DIR / ".credentials.json"
OUTPUT = PROBE_DIR / "output"

GRADE_URL = "https://jxw.sylu.edu.cn/cjcx"


async def fetch_raw(client, cookie, extra_data):
    """Call cjcx_cxXsgrcj.html with arbitrary form data. Return parsed json."""
    resp = await client.post(
        f"{GRADE_URL}/cjcx_cxXsgrcj.html",
        params={"doType": "query", "gnmkdm": "N305005"},
        data=extra_data,
        headers={"Cookie": cookie},
    )
    if resp.status_code != 200:
        return {"_http_status": resp.status_code, "_body": resp.text[:200]}
    try:
        return resp.json()
    except Exception as e:
        return {"_parse_error": str(e), "_body": resp.text[:200]}


async def main() -> int:
    if not CREDS.exists():
        print(f"凭据文件不存在: {CREDS}")
        return 1
    creds = json.loads(CREDS.read_text(encoding="utf-8"))
    student_id = creds["student_id"].strip()
    password = creds["password"]
    if not student_id or not password or student_id == "在此填学号":
        print("请先编辑 .credentials.json")
        return 1

    OUTPUT.mkdir(parents=True, exist_ok=True)
    report = {
        "student_id_masked": f"{student_id[:2]}***{student_id[-4:]}",
        "tests": [],
    }

    async with ProbeCrawler(timeout=20) as crawler:
        print("[0] 登录...")
        try:
            cookie = await crawler.login(student_id, password)
            print("  登录成功")
        except Exception as e:
            print(f"  登录失败: {type(e).__name__}: {e}")
            return 1
        client = crawler.client

        # --- A1: both empty ---
        print("\n[A1] xqm='', xnm='' (both empty)...")
        d = await fetch_raw(client, cookie, {
            "xnm": "", "xqm": "", "queryModel.showCount": "50",
        })
        n = len(d.get("items", [])) if isinstance(d, dict) else None
        print(f"    items={n}, top_keys={sorted(d.keys()) if isinstance(d, dict) else '-'}")
        report["tests"].append({"name": "A1_both_empty", "input": {"xnm": "", "xqm": ""},
                                "result": d if isinstance(d, dict) else {"raw": str(d)[:500]}})

        # --- A2: omit xnm/xqm entirely ---
        print("\n[A2] omit xnm/xqm entirely...")
        d = await fetch_raw(client, cookie, {"queryModel.showCount": "50"})
        n = len(d.get("items", [])) if isinstance(d, dict) else None
        print(f"    items={n}, top_keys={sorted(d.keys()) if isinstance(d, dict) else '-'}")
        report["tests"].append({"name": "A2_omit_both", "input": {},
                                "result": d if isinstance(d, dict) else {"raw": str(d)[:500]}})

        # --- A3: known good semester, large showCount, inspect pagination top fields ---
        print("\n[A3] known semester 2024/3, showCount=500 — inspect pagination fields...")
        d = await fetch_raw(client, cookie, {
            "xnm": "2024", "xqm": "3", "queryModel.showCount": "500",
        })
        if isinstance(d, dict):
            top = {k: d.get(k) for k in (
                "items", "currentPage", "currentResult", "limit", "offset",
                "pageNo", "pageSize", "showCount", "totalCount", "totalPage",
                "totalResult",
            )}
            # queryModel may carry these
            qm = d.get("queryModel") if isinstance(d.get("queryModel"), dict) else {}
            items = d.get("items", [])
            real_count = len(items) if isinstance(items, list) else None
            print(f"    items_count={real_count}")
            print(f"    top: {top}")
            print(f"    queryModel: {qm}")
            report["tests"].append({
                "name": "A3_known_sem_large_count",
                "input": {"xnm": "2024", "xqm": "3", "showCount": "500"},
                "items_count": real_count,
                "top_fields": top,
                "queryModel": qm,
            })

        # --- B1: paginate with tiny page to force multi-page ---
        print("\n[B1] 2024/3, showCount=2 — see totalPage & whether page 2 differs...")
        d1 = await fetch_raw(client, cookie, {
            "xnm": "2024", "xqm": "3",
            "queryModel.showCount": "2", "queryModel.currentPage": "1",
        })
        d2 = await fetch_raw(client, cookie, {
            "xnm": "2024", "xqm": "3",
            "queryModel.showCount": "2", "queryModel.currentPage": "2",
        })
        i1 = d1.get("items", []) if isinstance(d1, dict) else []
        i2 = d2.get("items", []) if isinstance(d2, dict) else []
        qm1 = d1.get("queryModel", {}) if isinstance(d1, dict) else {}
        print(f"    p1 items={len(i1)} p2 items={len(i2)}")
        print(f"    p1 keys: {list(i1[0].keys())[:5] if i1 else '-'}")
        print(f"    p1 queryModel: {qm1}")
        # Check overlap
        keys1 = {it.get("jxb_id") for it in i1 if isinstance(it, dict)}
        keys2 = {it.get("jxb_id") for it in i2 if isinstance(it, dict)}
        overlap = keys1 & keys2
        print(f"    overlap p1∩p2: {len(overlap)} (jxb_id)")
        report["tests"].append({
            "name": "B1_pagination_probe",
            "input_p1": {"xnm": "2024", "xqm": "3", "showCount": "2", "currentPage": "1"},
            "input_p2": {"xnm": "2024", "xqm": "3", "showCount": "2", "currentPage": "2"},
            "p1_items": len(i1), "p2_items": len(i2),
            "p1_queryModel": qm1,
            "overlap_jxb_id": len(overlap),
        })

        # --- B2: explicit large showCount vs small to confirm count is honored ---
        print("\n[B2] same semester, showCount=500 returns vs showCount=5...")
        d_big = await fetch_raw(client, cookie, {
            "xnm": "2024", "xqm": "3", "queryModel.showCount": "500",
        })
        d_small = await fetch_raw(client, cookie, {
            "xnm": "2024", "xqm": "3", "queryModel.showCount": "5",
        })
        big_n = len(d_big.get("items", [])) if isinstance(d_big, dict) else None
        small_n = len(d_small.get("items", [])) if isinstance(d_small, dict) else None
        print(f"    showCount=500 -> {big_n} items; showCount=5 -> {small_n} items")
        report["tests"].append({
            "name": "B2_showcount_compared",
            "showCount_500": big_n,
            "showCount_5": small_n,
            "diff": (big_n or 0) - (small_n or 0),
        })

        # Also total across all real semesters from A3-style big pulls
        print("\n[B3] sum of showCount=500 per semester (to compare with single all-query)...")
        total = 0
        per_sem = {}
        for y, s in [("2024", 3), ("2024", 12), ("2025", 3), ("2025", 12), ("2026", 3)]:
            d = await fetch_raw(client, cookie, {
                "xnm": y, "xqm": str(s), "queryModel.showCount": "500",
            })
            n = len(d.get("items", [])) if isinstance(d, dict) else 0
            per_sem[f"{y}_s{s}"] = n
            total += n
            print(f"    {y}_s{s}: {n}")
        print(f"    total per-semester sum: {total}")
        report["tests"].append({
            "name": "B3_per_semester_totals",
            "per_semester": per_sem,
            "sum": total,
        })

        out = OUTPUT / "supplementary_probe.json"
        out.write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str),
                       encoding="utf-8")
        print(f"\n报告 → {out}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))