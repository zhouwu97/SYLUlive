#!/usr/bin/env python3
"""
Edu Grade Structure Probe.

Probes the academic affairs grade API to:
1. Inventory all fields returned by the grade list endpoint
2. Compare original vs retake records for "大学外语1"
3. Discover grade detail endpoints from HTML/JS
4. Generate a field structure report

SECURITY:
- Password via getpass (never in args or env)
- No cookies/tokens written to disk
- All output sanitized (student IDs masked, names removed)
- Output files excluded from git via .gitignore

Usage:
    python tools/edu_probe/probe_grade_structure.py
"""

import asyncio
import getpass
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

# Add project root to path for imports
PROBE_DIR = Path(__file__).resolve().parent
PROJECT_DIR = PROBE_DIR.parent.parent
sys.path.insert(0, str(PROJECT_DIR))

from crawler_probe import EduCrawler
from sanitize import (
    sanitize_grade_item,
    sanitize_cookie,
    sanitize_student_id,
    build_field_inventory,
    sanitize_json_for_output,
)

OUTPUT_DIR = PROBE_DIR / "output"
REPORT_DIR = PROBE_DIR / "report"

# Target semesters — the user should adjust these based on their known
# "大学外语1" failed and retake semesters.
# These are defaults; the script will prompt for confirmation.
TARGET_SEMESTERS = [
    # ("year", semester_code, "description")
    # semester: 3 = first, 12 = second
]


def get_credentials() -> tuple[str, str]:
    """Get student ID and password interactively."""
    print("\n" + "=" * 50)
    print("  教务成绩结构探针")
    print("=" * 50)
    print()
    print("本轮只调查原始字段结构，不修改任何生产代码。")
    print("密码通过 getpass 读取，不会显示在终端。")
    print()

    student_id = input("学号: ").strip()
    if not student_id:
        print("错误: 请输入学号")
        sys.exit(1)

    password = getpass.getpass("教务密码: ").strip()
    if not password:
        print("错误: 请输入密码")
        sys.exit(1)

    return student_id, password


def prompt_semesters() -> list[tuple[str, int, str]]:
    """Prompt user for which semesters to probe."""
    print("\n请输入要探测的学期（至少两个）：")
    print("  学期值: 3 = 第一学期(秋季), 12 = 第二学期(春季)")
    print("  例如: 2024 12 表示 2024-2025 第二学期")
    print()

    semesters = []
    while True:
        entry = input("学年 学期 [例如 2024 12, 留空结束]: ").strip()
        if not entry:
            if len(semesters) < 2:
                print("至少需要两个学期（用于对照），请继续输入。")
                continue
            break
        parts = entry.split()
        if len(parts) != 2:
            print("格式错误，请用空格分隔学年和学期。")
            continue
        year, sem_str = parts
        semester = int(sem_str)
        if semester not in (3, 12):
            print("学期必须为 3 或 12。")
            continue
        desc = input("  描述（如 原考试/重修）: ").strip()
        semesters.append((year, semester, desc))
        print(f"  已添加: {year}-{int(year)+1} 第{'一' if semester==3 else '二'}学期 ({desc})")

    return semesters


async def probe_semester(
    crawler: EduCrawler,
    cookie: str,
    year: str,
    semester: int,
    description: str,
) -> Optional[tuple[List[Dict], Dict[str, Any]]]:
    """Probe a single semester and return (raw_items, field_inventory)."""
    print(f"\n  [{description}] 请求成绩: {year} 学期 {semester}")
    try:
        items = await crawler.fetch_grades(cookie, year, semester)
        print(f"    返回 {len(items)} 条记录")

        # Save raw field names
        field_names = {}
        if items:
            field_names = build_field_inventory(items)

        # Save sanitized version
        sanitized = [sanitize_grade_item(item) for item in items]

        # Write field names to output
        prefix = f"grade_list_{year}_{semester}"
        with open(OUTPUT_DIR / f"{prefix}_field_names.json", "w", encoding="utf-8") as f:
            json.dump(field_names, f, ensure_ascii=False, indent=2, default=str)

        with open(OUTPUT_DIR / f"{prefix}_sanitized.json", "w", encoding="utf-8") as f:
            json.dump(sanitized, f, ensure_ascii=False, indent=2, default=str)

        print(f"    字段清单 → output/{prefix}_field_names.json")
        print(f"    脱敏成绩 → output/{prefix}_sanitized.json")

        return items, field_names
    except Exception as e:
        print(f"    错误: {type(e).__name__}: {e}")
        return None


def find_course_records(
    items: List[Dict],
    course_name_keyword: str,
) -> List[Dict]:
    """Find records matching a course name keyword."""
    matches = []
    for item in items:
        kcmc = item.get("kcmc", "")
        if course_name_keyword in kcmc:
            matches.append(item)
    return matches


def build_comparison_matrix(
    original_records: List[Dict],
    retake_records: List[Dict],
    field_inventory: Dict[str, Any],
) -> str:
    """Build a markdown comparison matrix for original vs retake records."""
    all_fields = sorted(field_inventory.keys())

    lines = []
    lines.append("## 大学外语1 原考试 vs 重修记录对照\n")
    lines.append("| 字段 | 原考试记录 | 重修记录 | 说明 |")
    lines.append("|------|-----------|---------|------|")

    orig = original_records[0] if original_records else {}
    retake = retake_records[0] if retake_records else {}

    for field in all_fields:
        orig_val = orig.get(field, "-")
        retake_val = retake.get(field, "-")

        # Sanitize personal values
        if field.lower() in {"xh", "xsxh", "xsid"}:
            orig_val = sanitize_student_id(str(orig_val)) if orig_val else "-"
            retake_val = sanitize_student_id(str(retake_val)) if retake_val else "-"

        # Truncate long values
        orig_str = str(orig_val)[:80] if orig_val is not None else "-"
        retake_str = str(retake_val)[:80] if retake_val is not None else "-"

        note = ""
        if orig_str != retake_str and orig_str != "-" and retake_str != "-":
            note = "⚠ 不同"

        lines.append(f"| `{field}` | {orig_str} | {retake_str} | {note} |")

    return "\n".join(lines)


async def discover_detail_endpoints(
    crawler: EduCrawler,
    cookie: str,
) -> Dict[str, Any]:
    """
    Discover grade detail endpoints from the grade query page HTML.
    Does NOT make requests to unknown endpoints — only analyzes the page source.
    """
    import re
    import httpx

    discovered = {
        "page_url": "https://jxw.sylu.edu.cn/cjcx/cjcx_cxXsgrcj.html",
        "candidate_endpoints": [],
        "js_files": [],
        "inline_click_handlers": [],
        "keywords_found": {},
    }

    print("\n  分析成绩查询页面...")
    try:
        async with httpx.AsyncClient(verify=False, timeout=30) as client:
            resp = await client.get(
                "https://jxw.sylu.edu.cn/cjcx/cjcx_cxXsgrcj.html",
                headers={"Cookie": cookie},
            )
            html = resp.text

            if resp.status_code == 200:
                # Save sanitized HTML
                # Remove script content, cookie references
                html_safe = re.sub(r'<script[^>]*>.*?</script>', '<!-- script removed -->', html, flags=re.DOTALL)
                html_safe = re.sub(r'cookie.*?;', 'cookie=<redacted>;', html_safe, flags=re.IGNORECASE)
                with open(OUTPUT_DIR / "grade_page_sanitized.html", "w", encoding="utf-8") as f:
                    f.write(html_safe)
                print(f"    页面 HTML → output/grade_page_sanitized.html")

                # Find script tags
                scripts = re.findall(r'<script[^>]*src=["\']([^"\']+)["\'][^>]*>', html)
                discovered["js_files"] = scripts
                print(f"    发现 {len(scripts)} 个外部 JS 文件")

                # Find onclick, href patterns
                onclick_patterns = re.findall(r'onclick=["\']([^"\']{10,})["\']', html)
                discovered["inline_click_handlers"] = onclick_patterns[:20]  # max 20

                # Search for keywords
                keywords = [
                    "cjcx_", "xscj", "detail", "mx", "ls", "history",
                    "jxb_id", "kch_id", "kcmc", "ksxz", "cjbz",
                    "pscj", "qmcj", "zpcj", "bfzcj", "ksxz",
                ]
                for kw in keywords:
                    matches = re.findall(re.escape(kw), html, re.IGNORECASE)
                    if matches:
                        discovered["keywords_found"][kw] = len(matches)

            else:
                print(f"    页面请求失败: HTTP {resp.status_code}")

    except Exception as e:
        print(f"    页面分析错误: {e}")

    # Save discovered endpoints
    with open(OUTPUT_DIR / "discovered_endpoints.json", "w", encoding="utf-8") as f:
        json.dump(discovered, f, ensure_ascii=False, indent=2, default=str)

    print(f"    端点发现 → output/discovered_endpoints.json")
    return discovered


def generate_report(
    all_items: Dict[str, List[Dict]],
    field_inventories: Dict[str, Dict[str, Any]],
    comparison: str,
    endpoints: Dict[str, Any],
    student_id: str,
) -> str:
    """Generate the final markdown report."""
    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    lines = []
    lines.append("# 教务成绩抓取结构探测报告\n")
    lines.append(f"**生成时间**: {now}")
    lines.append(f"**探测账号**: {sanitize_student_id(student_id)}\n")

    lines.append("---\n")
    lines.append("## 1. 当前生产成绩调用链\n")
    lines.append("```")
    lines.append("Flutter → Go backend (:8080) → Python FastAPI (:8081)")
    lines.append("                               → EduCrawler")
    lines.append("                               → jxw.sylu.edu.cn/cjcx")
    lines.append("```\n")
    lines.append("**成绩列表接口**:")
    lines.append("- URL: `POST {GRADE_URL}/cjcx_cxXsgrcj.html?doType=query&gnmkdm=N305005`")
    lines.append("- 参数: `xnm` (学年), `xqm` (学期: 3/12), `queryModel.showCount=50`")
    lines.append("- 响应: `{\"items\": [...]}`\n")

    lines.append("## 2. 当前 GradeInfo 映射字段\n")
    lines.append("| GradeInfo 字段 | 原始字段 | 类型 |")
    lines.append("|---------------|---------|------|")
    lines.append("| name | kcmc | str |")
    lines.append("| class_id | jxb_id | str |")
    lines.append("| teacher | jsxm | str? |")
    lines.append("| is_degree | sfxwkc == \"是\" | bool |")
    lines.append("| credits | xf | float |")
    lines.append("| gpa | jd | float |")
    lines.append("| grade_points | xfjd | float |")
    lines.append("| fraction | bfzcj | float |")
    lines.append("| grade | cj | str |\n")

    lines.append("## 3. 原始 items 完整字段清单\n")
    lines.append("（合并所有探测学期的字段）\n")
    all_fields = set()
    for inv in field_inventories.values():
        all_fields.update(inv.keys())
    all_fields = sorted(all_fields)

    lines.append("| 字段 | 类型 | 非空数 | 最多3个样例 |")
    lines.append("|------|------|--------|-----------|")
    for field in all_fields:
        # Collect info from all semesters
        types = set()
        non_null = 0
        samples = []
        for inv in field_inventories.values():
            if field in inv:
                types.update(inv[field]["types"])
                non_null += inv[field]["non_null_count"]
                for s in inv[field].get("samples", []):
                    if len(samples) < 3 and s not in samples:
                        samples.append(s)

        type_str = "/".join(sorted(types))
        sample_str = ", ".join(str(s)[:40] for s in samples)
        lines.append(f"| `{field}` | {type_str} | {non_null} | {sample_str} |")

    lines.append("")
    lines.append("## 4. 大学外语1 原考试和重修记录对照\n")
    lines.append(comparison)

    lines.append("\n## 5. 成绩详情接口发现\n")
    lines.append(f"- 页面 JS 文件: {len(endpoints.get('js_files', []))} 个")
    lines.append(f"- 内联 onclick: {len(endpoints.get('inline_click_handlers', []))} 个")
    lines.append(f"- 关键词命中: {json.dumps(endpoints.get('keywords_found', {}), ensure_ascii=False)}\n")

    lines.append("## 6. 字段语义分析\n")
    lines.append("（待人工审查后填写）\n")

    lines.append("## 7. 当前错误原因\n")
    lines.append("（待分析后填写）\n")

    lines.append("## 8. 推荐新数据模型\n")
    lines.append("（待审查后设计，本轮不实施）\n")

    lines.append("---\n")
    lines.append("*本报告由 tools/edu_probe/probe_grade_structure.py 自动生成*")

    return "\n".join(lines)


async def main():
    # Get credentials
    student_id, password = get_credentials()

    # Get target semesters
    semesters = prompt_semesters()

    print(f"\n开始探测（账号 {sanitize_student_id(student_id)}）...")

    # Login
    print("\n[1/4] 登录教务系统...")
    crawler = EduCrawler()
    try:
        cookie = await crawler.login(student_id, password)
        print(f"  登录成功 (Cookie: {sanitize_cookie(cookie)})")
    except Exception as e:
        print(f"  登录失败: {type(e).__name__}: {e}")
        sys.exit(1)

    # Probe each semester
    print("\n[2/4] 探测各学期成绩列表...")
    all_items: Dict[str, List[Dict]] = {}
    field_inventories: Dict[str, Dict[str, Any]] = {}

    for year, semester, desc in semesters:
        result = await probe_semester(crawler, cookie, year, semester, desc)
        if result:
            items, inventory = result
            key = f"{year}_{semester}"
            all_items[key] = items
            field_inventories[key] = inventory

    # Find and compare大学外语1 records
    print("\n[3/4] 查找大学外语1记录...")
    comparison = "未找到大学外语1记录"
    for key, items in all_items.items():
        matches = find_course_records(items, "大学外语")
        if matches:
            print(f"  {key}: 找到 {len(matches)} 条记录")
            for m in matches:
                kcmc = m.get("kcmc", "")
                cj = m.get("cj", "")
                bfzcj = m.get("bfzcj", "")
                print(f"    - {kcmc}: cj={cj}, bfzcj={bfzcj}")

    # Build comparison if we have records from multiple semesters
    if len(all_items) >= 2:
        keys = list(all_items.keys())
        orig_key = keys[0]
        retake_key = keys[1]
        orig_records = find_course_records(all_items[orig_key], "大学外语")
        retake_records = find_course_records(all_items[retake_key], "大学外语")
        all_inventory = {}
        for inv in field_inventories.values():
            all_inventory.update(inv)

        if orig_records or retake_records:
            comparison = build_comparison_matrix(
                orig_records, retake_records, all_inventory
            )
            print(f"  对照矩阵已生成")

    # Discover detail endpoints
    print("\n[4/4] 分析成绩页面寻找详情接口...")
    endpoints = await discover_detail_endpoints(crawler, cookie)

    # Generate report
    print("\n生成报告...")
    report = generate_report(
        all_items, field_inventories, comparison, endpoints, student_id
    )
    report_path = REPORT_DIR / "grade_structure_report.md"
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"报告 → report/grade_structure_report.md")

    print("\n" + "=" * 50)
    print("  探测完成")
    print("=" * 50)
    print()
    print("输出文件:")
    for f in sorted(OUTPUT_DIR.glob("*.json")):
        print(f"  output/{f.name}")
    if (OUTPUT_DIR / "grade_page_sanitized.html").exists():
        print(f"  output/grade_page_sanitized.html")
    print(f"  report/grade_structure_report.md")
    print()
    print("下一步: 审查 grade_structure_report.md，确认字段语义。")
    print("在审查完成前，不要修改任何生产代码。")
    print(f"账号 {sanitize_student_id(student_id)} 的 Cookie 未写入任何文件。")


if __name__ == "__main__":
    asyncio.run(main())
