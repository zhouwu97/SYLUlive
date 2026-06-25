"""
Grade structure probe — login, fetch all semesters, dump raw JSON.

Usage:
    python tools/edu_probe/run_probe.py

What it does:
    1. Login with interactive credentials (getpass)
    2. Auto-probe all semesters from enrollment year to current
    3. Print full field list + values for any "大学外语" records
    4. Save all raw items to output/all_grades_raw.json
    5. Print field inventory (every field name + type + sample)

Output:
    output/all_grades_raw.json      — complete raw grade data
    output/field_inventory.json     — field name/type/sample inventory
"""
import asyncio
import getpass
import json
import sys
from pathlib import Path

# Add probe dir to path
PROBE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROBE_DIR))

from crawler_probe import ProbeCrawler

OUTPUT = PROBE_DIR / "output"


def enrollment_year(student_id: str) -> int:
    """Guess enrollment year from student ID prefix."""
    prefix = student_id[:2]
    return 2000 + int(prefix)


def semesters_to_probe(enrollment: int) -> list[tuple[str, int]]:
    """Build list of (year, semester) from enrollment to current."""
    now = 2026
    result = []
    for y in range(enrollment, now + 1):
        for s in [3, 12]:
            # Skip future: if current year and month suggests semester not yet available
            if y == now and s == 12:
                continue  # current spring semester, may or may not have grades
            result.append((str(y), s))
    return result


def build_inventory(all_data: dict) -> dict:
    """Build field inventory across all semesters."""
    inv = {}
    for key, items in all_data.items():
        for item in items:
            for k, v in item.items():
                if k not in inv:
                    inv[k] = {"count": 0, "non_null": 0, "types": set(), "samples": []}
                inv[k]["count"] += 1
                if v is not None and v != "" and v != []:
                    inv[k]["non_null"] += 1
                    if len(inv[k]["samples"]) < 3:
                        inv[k]["samples"].append(v)
                inv[k]["types"].add(type(v).__name__)
    for v in inv.values():
        v["types"] = sorted(v["types"])
    return inv


async def main():
    print("=" * 60)
    print("  教务成绩结构探针")
    print("=" * 60)
    print()
    print("本轮目标：抓取所有学期的原始成绩 JSON，找到大学外语1。")
    print("凭据通过 getpass 读取，不写文件。")
    print()

    student_id = input("学号: ").strip()
    if not student_id:
        print("请输入学号")
        return 1
    password = getpass.getpass("教务密码: ").strip()
    if not password:
        print("请输入密码")
        return 1

    enrollment = enrollment_year(student_id)
    targets = semesters_to_probe(enrollment)
    print(f"\n将探测 {len(targets)} 个学期 (入学 {enrollment} 年起)")

    # Login
    print("\n[1] 登录...")
    async with ProbeCrawler(timeout=20) as crawler:
        try:
            cookie = await crawler.login(student_id, password)
            print("  登录成功")
        except Exception as e:
            print(f"  登录失败: {e}")
            return 1

        # Fetch all semesters
        print(f"\n[2] 抓取 {len(targets)} 个学期...")
        all_data = {}
        for year, semester in targets:
            try:
                items = await crawler.fetch_grades(cookie, year, semester)
                key = f"{year}_s{semester}"
                all_data[key] = items
                label = f"{year}-{int(year)+1} 第{'一' if semester==3 else '二'}学期"
                print(f"  {label}: {len(items)} 条")

                # Dump matching records
                for item in items:
                    kcmc = item.get("kcmc", "")
                    if "大学外语" in kcmc:
                        cj = item.get("cj", "-")
                        bfzcj = item.get("bfzcj", "-")
                        print(f"    >> {kcmc}: cj={cj}, bfzcj={bfzcj}")
                        print(f"       全部字段: {sorted(item.keys())}")
                        for k, v in sorted(item.items()):
                            print(f"         {k}: {v}")
            except Exception as e:
                print(f"  {year} s{semester}: {type(e).__name__} — {e}")

        # Save raw data
        OUTPUT.mkdir(parents=True, exist_ok=True)
        raw_path = OUTPUT / "all_grades_raw.json"
        with open(raw_path, "w", encoding="utf-8") as f:
            json.dump(all_data, f, ensure_ascii=False, indent=2, default=str)
        print(f"\n  原始数据: {raw_path}")

        # Build and save inventory
        inv = build_inventory(all_data)
        inv_path = OUTPUT / "field_inventory.json"
        with open(inv_path, "w", encoding="utf-8") as f:
            json.dump(inv, f, ensure_ascii=False, indent=2, default=str)
        print(f"  字段清单: {inv_path}")

        # Print inventory summary
        print(f"\n[3] 字段清单 ({len(inv)} 个字段):")
        for field, info in sorted(inv.items()):
            types = "/".join(info["types"])
            samples = ", ".join(str(s)[:40] for s in info["samples"][:2])
            print(f"  {field:20s} {types:10s}  x{info['count']:>3}  {samples}")

        # Highlight missing fields
        print("\n[4] 当前生产代码 GradeInfo 只取 9 个字段:")
        used = {"kcmc", "jxb_id", "jsxm", "sfxwkc", "xf", "jd", "xfjd", "bfzcj", "cj"}
        unused = set(inv.keys()) - used
        if unused:
            print(f"  原始有但生产丢弃的字段 ({len(unused)} 个):")
            for f in sorted(unused):
                print(f"    {f}")
        else:
            print("  没有额外字段（原始 JSON 只有上述 9 个字段）")

        print(f"\n完成。请检查 {raw_path}")
        return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
