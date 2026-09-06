#!/usr/bin/env python3
"""Python ↔ Dart 成绩详情 Differential 比较工具。

使用方式：
    python compare.py python_result.json dart_result.json

输出：
    Missing / Extra / Changed / OrderOnlyChanged
"""
import json
import sys
from typing import Any, Dict, List, Tuple


def normalize_component(comp: Dict[str, Any]) -> Dict[str, Any]:
    """规范化 component 格式。"""
    return {
        'name': str(comp.get('name', '')).strip(),
        'weight': comp.get('weight'),
        'score': str(comp.get('score', '')).strip(),
    }


def components_equal(c1: Dict[str, Any], c2: Dict[str, Any]) -> bool:
    """比较两个 component 是否相等。"""
    return (
        c1['name'] == c2['name'] and
        c1['weight'] == c2['weight'] and
        c1['score'] == c2['score']
    )


def compare_detail(
    python_detail: Dict[str, Any],
    dart_detail: Dict[str, Any],
) -> Dict[str, Any]:
    """比较单个课程的成绩详情。

    返回：
        {
            'missing': 缺失的字段,
            'extra': 多余的字段,
            'changed': 变化的字段,
            'order_only_changed': 是否仅顺序不同,
        }
    """
    result = {
        'missing': [],
        'extra': [],
        'changed': [],
        'order_only_changed': False,
    }

    # 比较 success
    if python_detail.get('success') != dart_detail.get('success'):
        result['changed'].append({
            'field': 'success',
            'python': python_detail.get('success'),
            'dart': dart_detail.get('success'),
        })

    # 比较 course_name
    py_name = str(python_detail.get('course_name', '')).strip()
    dart_name = str(dart_detail.get('course_name', '')).strip()
    if py_name != dart_name:
        result['changed'].append({
            'field': 'course_name',
            'python': py_name,
            'dart': dart_name,
        })

    # 比较 total_grade
    py_total = str(python_detail.get('total_grade', '')).strip()
    dart_total = str(dart_detail.get('total_grade', '')).strip()
    if py_total != dart_total:
        result['changed'].append({
            'field': 'total_grade',
            'python': py_total,
            'dart': dart_total,
        })

    # 比较 components
    py_comps = [
        normalize_component(c)
        for c in python_detail.get('components', [])
    ]
    dart_comps = [
        normalize_component(c)
        for c in dart_detail.get('components', [])
    ]

    if len(py_comps) != len(dart_comps):
        result['changed'].append({
            'field': 'components.length',
            'python': len(py_comps),
            'dart': len(dart_comps),
        })
    else:
        # 有序比较
        order_matters = True
        for i, (py_comp, dart_comp) in enumerate(zip(py_comps, dart_comps)):
            if not components_equal(py_comp, dart_comp):
                order_matters = False
                result['changed'].append({
                    'field': f'components[{i}]',
                    'python': py_comp,
                    'dart': dart_comp,
                })

        # 如果有序比较不相等，检查无序集合是否相等
        if not order_matters:
            py_set = sorted(
                [json.dumps(c, sort_keys=True, ensure_ascii=False) for c in py_comps]
            )
            dart_set = sorted(
                [json.dumps(c, sort_keys=True, ensure_ascii=False) for c in dart_comps]
            )
            if py_set == dart_set:
                result['order_only_changed'] = True

    return result


def main():
    # 设置 stdout 编码为 UTF-8
    import codecs
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout.buffer, 'ignore')
    sys.stderr = codecs.getwriter('utf-8')(sys.stderr.buffer, 'ignore')

    if len(sys.argv) != 3:
        print('用法: python compare.py python_result.json dart_result.json', file=sys.stderr)
        sys.exit(1)

    python_path = sys.argv[1]
    dart_path = sys.argv[2]

    try:
        # 尝试多种编码
        for encoding in ['utf-8', 'gbk', 'gb2312', 'utf-8-sig']:
            try:
                with open(python_path, 'r', encoding=encoding) as f:
                    python_results = json.load(f)
                break
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
        else:
            raise ValueError('无法以任何已知编码读取 Python 结果文件')

        for encoding in ['utf-8', 'gbk', 'gb2312', 'utf-8-sig']:
            try:
                with open(dart_path, 'r', encoding=encoding) as f:
                    dart_results = json.load(f)
                break
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
        else:
            raise ValueError('无法以任何已知编码读取 Dart 结果文件')
    except Exception as e:
        print(f'错误: 无法读取文件: {e}', file=sys.stderr)
        sys.exit(1)

    if not isinstance(python_results, list) or not isinstance(dart_results, list):
        print('错误: 结果文件格式不正确', file=sys.stderr)
        sys.exit(1)

    if len(python_results) != len(dart_results):
        print(f'警告: Python 结果数量 ({len(python_results)}) 与 Dart 结果数量 ({len(dart_results)}) 不一致', file=sys.stderr)

    print('=' * 80)
    print('Python ↔ Dart 成绩详情 Differential 比较')
    print('=' * 80)
    print()

    total_missing = 0
    total_extra = 0
    total_changed = 0
    total_order_only = 0

    for i, (py_detail, dart_detail) in enumerate(zip(python_results, dart_results)):
        course_name = py_detail.get('course_name', dart_detail.get('course_name', f'课程 {i+1}'))
        print(f'课程 {i+1}: {course_name}')
        print('-' * 80)

        comparison = compare_detail(py_detail, dart_detail)

        if comparison['missing']:
            print(f'  Missing: {len(comparison["missing"])} 项')
            for item in comparison['missing']:
                print(f'    - {item}')
            total_missing += len(comparison['missing'])

        if comparison['extra']:
            print(f'  Extra: {len(comparison["extra"])} 项')
            for item in comparison['extra']:
                print(f'    - {item}')
            total_extra += len(comparison['extra'])

        if comparison['changed']:
            print(f'  Changed: {len(comparison["changed"])} 项')
            for item in comparison['changed']:
                print(f'    - {item["field"]}')
                print(f'      Python: {item["python"]}')
                print(f'      Dart:   {item["dart"]}')
            total_changed += len(comparison['changed'])

        if comparison['order_only_changed']:
            print('  OrderOnlyChanged: 是（components 内容相同但顺序不同）')
            total_order_only += 1

        if not any([
            comparison['missing'],
            comparison['extra'],
            comparison['changed'],
            comparison['order_only_changed'],
        ]):
            print('  ✓ 完全一致')

        print()

    print('=' * 80)
    print('总结')
    print('=' * 80)
    print(f'Missing:           {total_missing}')
    print(f'Extra:             {total_extra}')
    print(f'Changed:           {total_changed}')
    print(f'OrderOnlyChanged:  {total_order_only}')
    print()

    if total_missing == 0 and total_extra == 0 and total_changed == 0:
        print('✓ PASS: Python ↔ Dart 成绩详情完全一致')
        sys.exit(0)
    else:
        print('✗ FAIL: Python ↔ Dart 成绩详情存在差异')
        sys.exit(1)


if __name__ == '__main__':
    main()
