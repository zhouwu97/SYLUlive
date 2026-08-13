"""成绩空结果语义回归测试。"""

import asyncio
import json

import httpx
from services.crawler import EduCrawler


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
