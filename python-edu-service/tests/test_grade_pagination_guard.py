"""成绩分页必须能在上游不尊重 currentPage 时自行刹住。

原实现是 `while True`，终止完全依赖上游"返回满页就说明还有下一页"这个假设。
教务端点改版/参数名不匹配时，若对任意页码都返回同一批满 500 条，
`len(items) < page_size` 永远不成立，会无限翻页并持续打上游。
"""

import json

import httpx
import pytest

from services import crawler as crawler_module
from services.crawler import EduCrawler


class _FakeResponse:
    def __init__(self, text: str, content_type: str = "application/json", status_code: int = 200):
        self.text = text
        self.status_code = status_code
        self.headers = {"Content-Type": content_type}


class _FakeClient:
    """只实现 fetch_grades 需要的 get/post，并记录每次分页请求。"""

    def __init__(self, page_payload):
        self.headers = {"User-Agent": "pagination-guard-test"}
        self.cookies = httpx.Cookies()
        self.page_payload = page_payload
        self.page_requests = []

    async def get(self, url, params=None, headers=None):
        return _FakeResponse("<html><body>成绩查询</body></html>", "text/html")

    async def post(self, url, params=None, data=None, headers=None):
        self.page_requests.append(dict(data or {}))
        page = int((data or {}).get("queryModel.currentPage", "1"))
        return _FakeResponse(json.dumps({"items": self.page_payload(page)}))


def _item(index: int) -> dict:
    return {"kcmc": f"课程{index}", "cj": "90", "xf": "2"}


@pytest.fixture
def make_crawler(monkeypatch):
    def _make(page_payload):
        crawler = EduCrawler()
        client = _FakeClient(page_payload)
        crawler.client = client
        return crawler, client

    return _make


def _full_page(page: int, items=None):
    return [_item(i) for i in range(crawler_module.GRADE_PAGE_SIZE)]


@pytest.mark.asyncio
async def test_repeated_full_page_stops_early(make_crawler):
    """上游对任意页码返回同一批数据：第 2 页指纹相同即停止，不再继续打上游。"""
    crawler, client = make_crawler(lambda page: [_item(i) for i in range(crawler_module.GRADE_PAGE_SIZE)])

    items = await crawler.fetch_grades("JSESSIONID=test", "2025", 3)

    assert len(client.page_requests) == 2
    assert len(items) == crawler_module.GRADE_PAGE_SIZE


@pytest.mark.asyncio
async def test_distinct_full_pages_are_bounded_by_page_cap(make_crawler):
    """每页都不同且都满页：必须被页数/条数上限刹住，调用次数有界。"""

    def payload(page: int):
        base = (page - 1) * crawler_module.GRADE_PAGE_SIZE
        return [_item(base + i) for i in range(crawler_module.GRADE_PAGE_SIZE)]

    crawler, client = make_crawler(payload)

    items = await crawler.fetch_grades("JSESSIONID=test", "2025", 3)

    assert len(client.page_requests) == crawler_module.MAX_GRADE_PAGES
    assert len(items) == crawler_module.MAX_GRADE_ITEMS


@pytest.mark.asyncio
async def test_partial_last_page_still_terminates_normally(make_crawler):
    """正常场景不受影响：满页后跟一个不满页即结束。"""

    def payload(page: int):
        if page == 1:
            return [_item(i) for i in range(crawler_module.GRADE_PAGE_SIZE)]
        return [_item(10000 + i) for i in range(10)]

    crawler, client = make_crawler(payload)

    items = await crawler.fetch_grades("JSESSIONID=test", "2025", 3)

    assert len(client.page_requests) == 2
    assert len(items) == crawler_module.GRADE_PAGE_SIZE + 10


@pytest.mark.asyncio
async def test_empty_first_page_returns_no_items(make_crawler):
    """本学期无成绩：一次请求后正常返回空列表。"""
    crawler, client = make_crawler(lambda page: [])

    items = await crawler.fetch_grades("JSESSIONID=test", "2025", 3)

    assert len(client.page_requests) == 1
    assert items == []
