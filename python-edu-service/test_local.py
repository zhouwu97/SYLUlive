"""
本地测试：直接用爬虫登录正方教务并获取课表 raw JSON
不经过 API 服务，不写数据库，只看原始数据
"""
import asyncio
import sys
import json
import io

# Fix Windows GBK encoding
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

sys.path.insert(0, '.')

from services.crawler import EduCrawler, CourseNotOpenError, LoginFailedError

STUDENT_ID = "2403060128"
PASSWORD = "@Zhoukangwu0"
YEAR = "2025"
SEMESTER = 12  # 春季 = 12, 秋季 = 3


async def main():
    print(f"=== 本地爬虫测试 ===")
    print(f"学号: {STUDENT_ID}")
    print(f"学年: {YEAR}, 学期: {SEMESTER} ({'第二学期(春)' if SEMESTER == 12 else '第一学期(秋)'})\n")

    async with EduCrawler(timeout=30.0) as crawler:
        # Step 1: 登录
        print("--- Step 1: 登录正方教务 ---")
        try:
            cookie = await crawler.login(STUDENT_ID, PASSWORD)
            print(f"[OK] 登录成功, Cookie: {cookie[:60]}...")
        except LoginFailedError as e:
            print(f"[FAIL] 登录失败: {e}")
            return
        except Exception as e:
            print(f"[FAIL] 登录异常: {e}")
            return

        # Step 2: 获取学生信息
        print("\n--- Step 2: 获取学生信息 ---")
        try:
            info = await crawler.get_student_info(cookie, STUDENT_ID)
            print(f"  姓名: {info.name}")
            print(f"  年级: {info.grade}")
            print(f"  学院: {info.college}")
            print(f"  专业: {info.major}")
        except Exception as e:
            print(f"  [WARN] 获取信息失败: {e}")

        # Step 3: 抓取课表（会打印 [DESK]/[MOBILE] 日志）
        print(f"\n--- Step 3: 抓取课表 ({YEAR}-{SEMESTER}) ---")
        try:
            courses = await crawler.fetch_courses(cookie, YEAR, SEMESTER)
            print(f"\n[OK] 成功获取 {len(courses)} 门课:")
            for i, c in enumerate(courses, 1):
                print(f"  {i}. {c.name} | {c.teacher} | {c.location} | 周{c.week_day} | {c.time} | {c.week_str}")
        except CourseNotOpenError as e:
            print(f"[FAIL] 课表未开放: {e}")
        except Exception as e:
            print(f"[FAIL] 抓取异常: {e}")

    print("\n=== 测试完成 ===")
