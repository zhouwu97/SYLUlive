"""成绩空结果语义回归测试。"""

import asyncio
import json

import httpx
from services.crawler import EduCrawler
from models.schemas import GradeInfo


def test_fetch_grades_returns_empty_list_for_valid_empty_response() -> None:
    """教务接口成功返回空数组表示暂无成绩，不应被当成抓取故障。"""

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return httpx.Response(
                200,
                text="<html><title>学生成绩查询</title></html>",
                headers={"content-type": "text/html; charset=utf-8"},
            )
        return httpx.Response(
            200,
            text=json.dumps({"items": [], "totalResult": 0}),
            headers={"content-type": "application/json; charset=utf-8"},
        )

    crawler = EduCrawler()
    crawler.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    async def run_case() -> list[dict]:
        try:
            return await crawler.fetch_grades("JSESSIONID=test", "2026", 3)
        finally:
            await crawler.client.aclose()

    assert asyncio.run(run_case()) == []


def test_grade_response_keeps_legacy_fields_for_existing_clients() -> None:
    grade = GradeInfo(
        name="数字图像处理",
        course_id="KC002",
        course_code="IMG201",
        class_id="JXB002",
        student_grade_id="XH002",
        teacher="李老师",
        is_degree=True,
        credits=2.5,
        gpa=3.5,
        grade_points=8.75,
        fraction=85,
        grade="85",
        exam_type="正常考试",
        course_category="专业选修",
        assessment_method="考试",
    ).model_dump(mode="json")

    assert {key: grade[key] for key in (
        "kcmc", "jxb_id", "xf", "jd", "cj", "sfxwkc",
    )} == {
        "kcmc": "数字图像处理",
        "jxb_id": "JXB002",
        "xf": 2.5,
        "jd": 3.5,
        "cj": "85",
        "sfxwkc": "是",
    }
