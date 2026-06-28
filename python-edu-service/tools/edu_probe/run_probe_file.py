"""
Non-interactive probe runner — reads credentials from .credentials.json
(gitignored), runs the probe, saves raw data. Does NOT auto-delete the
creds file; you edit/rm it yourself when done.

Usage:
    python tools/edu_probe/run_probe_file.py
"""
import asyncio
import json
import sys
from pathlib import Path

PROBE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROBE_DIR))

from crawler_probe import ProbeCrawler

CREDS = PROBE_DIR / ".credentials.json"
OUTPUT = PROBE_DIR / "output"


def enrollment_year(student_id: str) -> int:
    return 2000 + int(student_id[:2])


def semesters_to_probe(enrollment: int) -> list[tuple[str, int]]:
    now = 2026
    result = []
    for y in range(enrollment, now + 1):
        for s in [3, 12]:
            if y == now and s == 12:
                continue
            result.append((str(y), s))
    return result


def build_inventory(all_data: dict) -> dict:
    inv = {}
    for items in all_data.values():
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


async def main() -> int:
    if not CREDS.exists():
        print(f"凭据文件不存在: {CREDS}")
        print("请先在该位置创建 .credentials.json，内容:")
        print('  {"student_id": "...", "password": "..."}')
        return 1

    try:
        creds = json.loads(CREDS.read_text(encoding="utf-8"))
        student_id = creds["student_id"].strip()
        password = creds["password"]
    except (KeyError, json.JSONDecodeError) as e:
        print(f"凭据文件格式错误: {e}")
        return 1

    if not student_id or not password or student_id == "在此填学号":
        print("请先编辑 .credentials.json，填入真实学号密码")
        return 1

    enrollment = enrollment_year(student_id)
    targets = semesters_to_probe(enrollment)
    print(f"学号: {student_id[:2]}***{student_id[-4:]} (入学 {enrollment})")
    print(f"将探测 {len(targets)} 个学期")

    print("\n[1] 登录...")
    async with ProbeCrawler(timeout=20) as crawler:
        try:
            cookie = await crawler.login(student_id, password)
            print("  登录成功")
        except Exception as e:
            print(f"  登录失败: {type(e).__name__}: {e}")
            return 1

        print(f"\n[2] 抓取 {len(targets)} 个学期...")
        all_data = {}
        dxb = []  # 大学外语记录
        for year, semester in targets:
            try:
                items = await crawler.fetch_grades(cookie, year, semester)
                key = f"{year}_s{semester}"
                all_data[key] = items
                label = f"{year}-{int(year)+1} {'一' if semester==3 else '二'}学期"
                print(f"  {label}: {len(items)} 条")
                for item in items:
                    kcmc = item.get("kcmc", "")
                    if "大学外语" in kcmc:
                        cj = item.get("cj", "-")
                        bfzcj = item.get("bfzcj", "-")
                        ksxz = item.get("ksxz", "(无)")
                        cjbz = item.get("cjbz", "(无)")
                        print(f"    >> {kcmc} [{label}]")
                        print(f"       cj={cj} bfzcj={bfzcj} ksxz={ksxz} cjbz={cjbz}")
                        dxb.append({"semester": label, "item": item})
            except Exception as e:
                print(f"  {year} s{semester}: {type(e).__name__} — {e}")

        OUTPUT.mkdir(parents=True, exist_ok=True)
        raw_path = OUTPUT / "all_grades_raw.json"
        with open(raw_path, "w", encoding="utf-8") as f:
            json.dump(all_data, f, ensure_ascii=False, indent=2, default=str)
        print(f"\n  原始数据: {raw_path}")

        inv = build_inventory(all_data)
        inv_path = OUTPUT / "field_inventory.json"
        with open(inv_path, "w", encoding="utf-8") as f:
            json.dump(inv, f, ensure_ascii=False, indent=2, default=str)
        print(f"  字段清单: {inv_path}")

        print(f"\n[3] 字段清单 ({len(inv)} 个字段):")
        for field, info in sorted(inv.items()):
            types = "/".join(info["types"])
            samples = ", ".join(str(s)[:40] for s in info["samples"][:2])
            print(f"  {field:24s} {types:10s}  x{info['count']:>3}  {samples}")

        used = {"kcmc", "jxb_id", "jsxm", "sfxwkc", "xf", "jd", "xfjd", "bfzcj", "cj"}
        unused = set(inv.keys()) - used
        if unused:
            print(f"\n[4] 生产 GradeInfo 丢弃的字段 ({len(unused)} 个):")
            for f in sorted(unused):
                print(f"    {f}")
        else:
            print("\n[4] 无额外字段")

        # 单独保存大学外语对比块
        if dxb:
            foci_path = OUTPUT / "daxuewaiyu_records.json"
            with open(foci_path, "w", encoding="utf-8") as f:
                json.dump(dxb, f, ensure_ascii=False, indent=2, default=str)
            print(f"\n  大学外语记录: {foci_path}")

        print(f"\n完成。")
        return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))