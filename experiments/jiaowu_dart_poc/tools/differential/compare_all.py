#!/usr/bin/env python3
"""三大功能 Python ↔ Dart differential 比较工具

比较：
- Academic Situation (学业情况/GPA)
- Credit Requirement (学分要求)
- Grade Detail (成绩详情)
"""
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple


def run_query(script: str, description: str) -> Dict[str, Any]:
    """运行查询脚本并返回结果"""
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"运行 {description}...", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

    result = subprocess.run(
        script,
        shell=True,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"❌ {description} 失败:", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"❌ {description} 输出无法解析为 JSON:", file=sys.stderr)
        print(f"stdout: {result.stdout}", file=sys.stderr)
        print(f"错误: {e}", file=sys.stderr)
        sys.exit(1)


def compare_floats(py_val: Any, dart_val: Any, field: str, tolerance: float = 0.01) -> Tuple[bool, str]:
    """比较浮点数值"""
    try:
        py_f = float(py_val) if py_val is not None else None
        dart_f = float(dart_val) if dart_val is not None else None

        if py_f is None and dart_f is None:
            return True, ""
        if py_f is None or dart_f is None:
            return False, f"  ❌ {field}: Python={py_val}, Dart={dart_val}"
        if abs(py_f - dart_f) > tolerance:
            return False, f"  ❌ {field}: Python={py_val}, Dart={dart_val} (diff={abs(py_f - dart_f):.4f})"
        return True, ""
    except (ValueError, TypeError):
        if py_val == dart_val:
            return True, ""
        return False, f"  ❌ {field}: Python={py_val}, Dart={dart_val}"


def compare_academic_situation(py_data: Dict, dart_data: Dict) -> Tuple[int, int, int]:
    """比较学业情况数据

    返回 (missing_count, extra_count, changed_count)
    """
    print("\n" + "="*60, file=sys.stderr)
    print("比较 Academic Situation (学业情况)", file=sys.stderr)
    print("="*60, file=sys.stderr)

    missing = 0
    extra = 0
    changed = 0

    if not py_data.get("success") or not dart_data.get("success"):
        print(f"⚠️  跳过: Python success={py_data.get('success')}, Dart success={dart_data.get('success')}", file=sys.stderr)
        return missing, extra, changed

    # 比较 GPA
    match, msg = compare_floats(py_data.get("all_gpa"), dart_data.get("all_gpa"), "all_gpa")
    if not match:
        print(msg, file=sys.stderr)
        changed += 1

    match, msg = compare_floats(py_data.get("degree_gpa"), dart_data.get("degree_gpa"), "degree_gpa")
    if not match:
        print(msg, file=sys.stderr)
        changed += 1

    # 比较统计数据
    stats_fields = [
        "total_courses", "passed_courses", "failed_courses",
        "not_started_courses", "in_progress_courses",
        "degree_total_courses", "degree_passed_courses",
        "degree_failed_courses", "degree_not_started_courses",
        "degree_in_progress_courses",
    ]

    for field in stats_fields:
        py_val = py_data.get(field)
        dart_val = dart_data.get(field)
        match, msg = compare_floats(py_val, dart_val, field)
        if not match:
            print(msg, file=sys.stderr)
            changed += 1

    # 比较课程数量
    py_courses = py_data.get("courses", [])
    dart_courses = dart_data.get("courses", [])

    if len(py_courses) != len(dart_courses):
        print(f"  ❌ courses count: Python={len(py_courses)}, Dart={len(dart_courses)}", file=sys.stderr)
        changed += 1

    print(f"\n✅ Academic Situation: Missing={missing}, Extra={extra}, Changed={changed}", file=sys.stderr)
    return missing, extra, changed


def compare_credit_requirement(py_data: Dict, dart_data: Dict) -> Tuple[int, int, int]:
    """比较学分要求数据

    返回 (missing_count, extra_count, changed_count)
    """
    print("\n" + "="*60, file=sys.stderr)
    print("比较 Credit Requirement (学分要求)", file=sys.stderr)
    print("="*60, file=sys.stderr)

    missing = 0
    extra = 0
    changed = 0

    if not py_data.get("success") or not dart_data.get("success"):
        print(f"⚠️  跳过: Python success={py_data.get('success')}, Dart success={dart_data.get('success')}", file=sys.stderr)
        return missing, extra, changed

    # 比较 status
    if py_data.get("status") != dart_data.get("status"):
        print(f"  ❌ status: Python={py_data.get('status')}, Dart={dart_data.get('status')}", file=sys.stderr)
        changed += 1

    # 比较模块数量
    py_modules = py_data.get("modules", [])
    dart_modules = dart_data.get("modules", [])

    if len(py_modules) != len(dart_modules):
        print(f"  ❌ modules count: Python={len(py_modules)}, Dart={len(dart_modules)}", file=sys.stderr)
        changed += 1
    else:
        print(f"  ✅ modules count: {len(py_modules)}", file=sys.stderr)

    # 比较每个模块的关键字段
    for i, (py_mod, dart_mod) in enumerate(zip(py_modules, dart_modules)):
        prefix = f"modules[{i}]"

        if py_mod.get("name") != dart_mod.get("name"):
            print(f"  ❌ {prefix}.name: Python={py_mod.get('name')}, Dart={dart_mod.get('name')}", file=sys.stderr)
            changed += 1

        match, msg = compare_floats(py_mod.get("required_credits"), dart_mod.get("required_credits"), f"{prefix}.required_credits")
        if not match:
            print(f"  {msg}", file=sys.stderr)
            changed += 1

        match, msg = compare_floats(py_mod.get("earned_credits"), dart_mod.get("earned_credits"), f"{prefix}.earned_credits")
        if not match:
            print(f"  {msg}", file=sys.stderr)
            changed += 1

    # 比较待提升课程数量
    py_improvement = py_data.get("improvement_courses", [])
    dart_improvement = dart_data.get("improvement_courses", [])

    if len(py_improvement) != len(dart_improvement):
        print(f"  ❌ improvement_courses count: Python={len(py_improvement)}, Dart={len(dart_improvement)}", file=sys.stderr)
        changed += 1
    else:
        print(f"  ✅ improvement_courses count: {len(py_improvement)}", file=sys.stderr)

    print(f"\n✅ Credit Requirement: Missing={missing}, Extra={extra}, Changed={changed}", file=sys.stderr)
    return missing, extra, changed


def compare_grade_details(py_data: List[Dict], dart_data: List[Dict]) -> Tuple[int, int, int]:
    """比较成绩详情数据

    返回 (missing_count, extra_count, changed_count)
    """
    print("\n" + "="*60, file=sys.stderr)
    print("比较 Grade Details (成绩详情)", file=sys.stderr)
    print("="*60, file=sys.stderr)

    missing = 0
    extra = 0
    changed = 0

    if len(py_data) != len(dart_data):
        print(f"  ⚠️  课程数量不同: Python={len(py_data)}, Dart={len(dart_data)}", file=sys.stderr)

    for i in range(min(len(py_data), len(dart_data))):
        py_detail = py_data[i]
        dart_detail = dart_data[i]

        course_name = py_detail.get("course_name", f"课程{i+1}")
        print(f"\n  课程 {i+1}: {course_name}", file=sys.stderr)

        if not py_detail.get("success") or not dart_detail.get("success"):
            print(f"    ⚠️  跳过: Python success={py_detail.get('success')}, Dart success={dart_detail.get('success')}", file=sys.stderr)
            continue

        # 比较总评
        py_total = py_detail.get("total_grade", "")
        dart_total = dart_detail.get("total_grade", "")
        match, msg = compare_floats(py_total, dart_total, "total_grade")
        if not match:
            print(f"    {msg}", file=sys.stderr)
            changed += 1

        # 比较成绩构成
        py_components = py_detail.get("components", [])
        dart_components = dart_detail.get("components", [])

        if len(py_components) != len(dart_components):
            print(f"    ❌ components count: Python={len(py_components)}, Dart={len(dart_components)}", file=sys.stderr)
            changed += 1
        else:
            print(f"    ✅ components count: {len(py_components)}", file=sys.stderr)

    print(f"\n✅ Grade Details: Missing={missing}, Extra={extra}, Changed={changed}", file=sys.stderr)
    return missing, extra, changed


def main():
    # 运行 Python 查询
    py_result = run_query(
        "python tools/differential/python_query_all.py",
        "Python 查询"
    )

    # 运行 Dart 查询
    dart_result = run_query(
        "dart run tools/differential/dart_query_all.dart",
        "Dart 查询"
    )

    # 比较结果
    print("\n" + "="*60, file=sys.stderr)
    print("开始数据比较", file=sys.stderr)
    print("="*60, file=sys.stderr)

    total_missing = 0
    total_extra = 0
    total_changed = 0

    # 比较学业情况
    m, e, c = compare_academic_situation(
        py_result.get("academic_situation", {}),
        dart_result.get("academic_situation", {})
    )
    total_missing += m
    total_extra += e
    total_changed += c

    # 比较学分要求
    m, e, c = compare_credit_requirement(
        py_result.get("credit_requirement", {}),
        dart_result.get("credit_requirement", {})
    )
    total_missing += m
    total_extra += e
    total_changed += c

    # 比较成绩详情
    m, e, c = compare_grade_details(
        py_result.get("grade_details", []),
        dart_result.get("grade_details", [])
    )
    total_missing += m
    total_extra += e
    total_changed += c

    # 输出最终结果
    print("\n" + "="*60, file=sys.stderr)
    print("最终统计", file=sys.stderr)
    print("="*60, file=sys.stderr)
    print(f"Missing: {total_missing}", file=sys.stderr)
    print(f"Extra: {total_extra}", file=sys.stderr)
    print(f"Changed: {total_changed}", file=sys.stderr)

    if total_missing == 0 and total_extra == 0 and total_changed == 0:
        print("\n🎉 完美！Python ↔ Dart 数据完全一致！", file=sys.stderr)
        sys.exit(0)
    else:
        print(f"\n⚠️  发现 {total_missing + total_extra + total_changed} 处差异", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
