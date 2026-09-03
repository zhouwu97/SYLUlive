#!/usr/bin/env python3
"""Python 端成绩详情查询工具。

用于 Python ↔ Dart differential 验证。

使用方式：
    python python_query.py

环境变量：
    JIAOWU_USERNAME: 学号
    JIAOWU_PASSWORD: 密码
"""
import asyncio
import json
import os
import sys
from pathlib import Path

# 添加 python-edu-service 到路径
edu_service_path = Path(__file__).parent.parent.parent.parent.parent / "python-edu-service"
sys.path.insert(0, str(edu_service_path))

try:
    from services.crawler import EduCrawler
except ImportError as e:
    print(f"错误: 无法导入 EduCrawler: {e}", file=sys.stderr)
    print(f"请确保 python-edu-service 位于: {edu_service_path}", file=sys.stderr)
    sys.exit(1)


async def main():
    username = os.environ.get('JIAOWU_USERNAME')
    password = os.environ.get('JIAOWU_PASSWORD')

    if not username or not password:
        print('错误: 缺少环境变量 JIAOWU_USERNAME 或 JIAOWU_PASSWORD', file=sys.stderr)
        sys.exit(1)

    try:
        crawler = EduCrawler(username, password)

        # 登录
        print('正在登录...', file=sys.stderr)
        await crawler.login()
        print('登录成功', file=sys.stderr)

        # 获取成绩列表
        print('正在获取成绩列表...', file=sys.stderr)
        grades = await crawler.fetch_grades()
        print(f'获取到 {len(grades)} 条成绩记录', file=sys.stderr)

        if not grades:
            print('警告: 没有成绩记录', file=sys.stderr)
            return

        # 选择有完整 ID 的成绩
        valid_grades = [
            g for g in grades
            if g.get('jxb_id') and g.get('kcmc')
        ]

        if not valid_grades:
            print('警告: 没有包含完整 ID 的成绩记录', file=sys.stderr)
            return

        print(f'找到 {len(valid_grades)} 条有效成绩记录', file=sys.stderr)

        # 查询前两门课程的成绩详情
        results = []

        for i, grade in enumerate(valid_grades[:2]):
            print(f'正在查询课程 {i + 1}/{min(len(valid_grades), 2)}: {grade["kcmc"]}', file=sys.stderr)

            try:
                detail = await crawler.fetch_grade_detail(
                    year=grade['xnm'],
                    semester=int(grade['xqm']),
                    class_id=grade['jxb_id'],
                    course_name=grade['kcmc'],
                    course_id=grade.get('kch_id'),
                    student_grade_id=grade.get('xh_id'),
                )

                results.append({
                    'success': detail.get('success', False),
                    'course_name': detail.get('course_name', ''),
                    'total_grade': detail.get('total_grade', ''),
                    'components': [
                        {
                            'name': c.get('name', ''),
                            'weight': c.get('weight'),
                            'score': c.get('score', ''),
                        }
                        for c in detail.get('components', [])
                    ],
                    'query_params': {
                        'year': grade['xnm'],
                        'semester': int(grade['xqm']),
                        'class_id': grade['jxb_id'],
                        'course_name': grade['kcmc'],
                        'course_id': grade.get('kch_id'),
                        'student_grade_id': grade.get('xh_id'),
                    },
                })

                print(f'  成功: {detail.get("success")}, 分项数: {len(detail.get("components", []))}', file=sys.stderr)
            except Exception as e:
                print(f'  查询失败: {e}', file=sys.stderr)
                results.append({
                    'success': False,
                    'course_name': grade['kcmc'],
                    'error': str(e),
                    'query_params': {
                        'year': grade['xnm'],
                        'semester': int(grade['xqm']),
                        'class_id': grade['jxb_id'],
                        'course_name': grade['kcmc'],
                    },
                })

        # 输出 JSON 到 stdout
        print(json.dumps(results, ensure_ascii=False))
        print('\n查询完成', file=sys.stderr)

    except Exception as e:
        print(f'错误: {e}', file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
    finally:
        if 'crawler' in locals():
            await crawler.close()


if __name__ == '__main__':
    asyncio.run(main())
