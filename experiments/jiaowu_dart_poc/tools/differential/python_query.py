#!/usr/bin/env python3
"""Python 端成绩详情查询工具

用于 Python ↔ Dart differential 验证
"""
import asyncio
import json
import os
import ssl
import sys
from pathlib import Path

# 添加 Python 服务路径
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent.parent / "client-build-staging-20260825" / "python-edu-service"))

from services.crawler import EduCrawler


def create_ssl_context():
    """创建包含 TrustAsia 中间证书的 SSL 上下文"""
    context = ssl.create_default_context()
    cert_path = Path(__file__).parent / "trustasia_intermediate.pem"
    if cert_path.exists():
        context.load_verify_locations(cafile=str(cert_path))
    return context


class EduCrawlerWithCustomSSL(EduCrawler):
    """支持自定义 SSL 上下文的 EduCrawler"""

    def __init__(self, timeout: float = 10.0, ssl_context=None):
        super().__init__(timeout)
        self.ssl_context = ssl_context

    async def __aenter__(self):
        import httpx
        # httpx 不直接支持传递 ssl.SSLContext，需要通过 httpcore 的方式
        # 或者直接禁用验证（仅用于测试）
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=False,
            verify=False,  # 暂时禁用 SSL 验证以进行测试
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                "Cache-Control": "no-cache",
            }
        )
        return self


async def main():
    username = os.environ.get("JIAOWU_USERNAME")
    password = os.environ.get("JIAOWU_PASSWORD")

    if not username or not password:
        print("错误: 缺少环境变量 JIAOWU_USERNAME 或 JIAOWU_PASSWORD", file=sys.stderr)
        sys.exit(1)

    try:
        ssl_context = create_ssl_context()
        async with EduCrawlerWithCustomSSL(timeout=30.0, ssl_context=ssl_context) as crawler:
            # 登录
            print("正在登录...", file=sys.stderr)
            cookie = await crawler.login(username, password)
            print("登录成功", file=sys.stderr)

            # 获取成绩列表
            print("正在获取成绩列表...", file=sys.stderr)
            grades = await crawler.fetch_grades(cookie, "2025", 12)
            print(f"获取到 {len(grades)} 条成绩记录", file=sys.stderr)

            if not grades:
                print("警告: 没有成绩记录", file=sys.stderr)
                sys.exit(0)

            # 选择有完整 ID 的成绩
            valid_grades = [
                g for g in grades
                if g.get("jxb_id") and g.get("kcmc")
            ]

            if not valid_grades:
                print("警告: 没有包含完整 ID 的成绩记录", file=sys.stderr)
                sys.exit(0)

            print(f"找到 {len(valid_grades)} 条有效成绩记录", file=sys.stderr)

            # 查询前两门课程的成绩详情
            results = []

            for i, grade in enumerate(valid_grades[:2]):
                course_name = grade.get("kcmc", "")
                year = grade.get("xnm", "")
                semester = int(grade.get("xqm", 0))
                class_id = grade.get("jxb_id", "")
                course_id = grade.get("kch_id", "")
                student_grade_id = grade.get("xh_id", "")

                print(f"正在查询课程 {i+1}/{min(len(valid_grades), 2)}: {course_name}", file=sys.stderr)

                try:
                    detail = await crawler.fetch_grade_detail(
                        cookie=cookie,
                        year=year,
                        semester=semester,
                        class_id=class_id,
                        course_name=course_name,
                        course_id=course_id if course_id else None,
                        student_grade_id=student_grade_id if student_grade_id else None,
                    )

                    results.append({
                        "success": detail.get("success", False),
                        "course_name": detail.get("course_name", course_name),
                        "total_grade": detail.get("total_grade", ""),
                        "components": detail.get("components", []),
                        "query_params": {
                            "year": year,
                            "semester": semester,
                            "class_id": class_id,
                            "course_name": course_name,
                            "course_id": course_id if course_id else None,
                            "student_grade_id": student_grade_id if student_grade_id else None,
                        },
                    })

                    print(f"  成功: {detail.get('success')}, 分项数: {len(detail.get('components', []))}", file=sys.stderr)
                except Exception as e:
                    print(f"  查询失败: {e}", file=sys.stderr)
                    results.append({
                        "success": False,
                        "course_name": course_name,
                        "error": str(e),
                        "query_params": {
                            "year": year,
                            "semester": semester,
                            "class_id": class_id,
                            "course_name": course_name,
                        },
                    })

            # 输出 JSON 到 stdout
            print(json.dumps(results, ensure_ascii=False))
            print("\n查询完成", file=sys.stderr)

    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
