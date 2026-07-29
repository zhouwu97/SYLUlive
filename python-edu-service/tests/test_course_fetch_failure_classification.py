"""课表拉取失败必须按原因分类，不能一律显示成“暂未排课”。

原实现把两个端点的所有异常都吞掉，然后统一抛 CourseNotOpenError。这样
Cookie 失效、教务返回登录页、响应体不是 JSON、字段改名，对用户都变成
“当前学期课表暂未排课”：既不触发重新登录，也无法从日志定位断点。
"""

import asyncio
import types

import pytest

from services.crawler import (
    CookieLapseError,
    CourseNotOpenError,
    EduCrawler,
    NetworkError,
)


class _FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text

    def json(self):
        import json

        return json.loads(self.text)


class _FakeClient:
    """按顺序返回预置响应，桌面端与移动端各消费一个。"""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = 0

    async def post(self, *args, **kwargs):
        self.calls += 1
        if not self._responses:
            raise AssertionError("unexpected extra request")
        return self._responses.pop(0)


def _crawler(responses) -> EduCrawler:
    crawler = EduCrawler.__new__(EduCrawler)
    crawler.client = _FakeClient(responses)
    return crawler


def _fetch(crawler):
    return asyncio.run(crawler.fetch_courses("cookie", "2026", 3))


def test_valid_empty_schedule_is_reported_as_not_open():
    crawler = _crawler([
        _FakeResponse(200, '{"kbList":[]}'),
        _FakeResponse(200, '{"kbList":[]}'),
    ])

    with pytest.raises(CourseNotOpenError):
        _fetch(crawler)


def test_login_page_with_http_200_is_a_session_lapse():
    # 教务系统有时不发 302，而是直接用 200 返回登录页。
    crawler = _crawler([
        _FakeResponse(200, '<html><form action="login_slogin.html">统一身份认证</form></html>'),
    ])

    with pytest.raises(CookieLapseError):
        _fetch(crawler)


def test_redirect_is_a_session_lapse():
    crawler = _crawler([_FakeResponse(302, "")])

    with pytest.raises(CookieLapseError):
        _fetch(crawler)


@pytest.mark.parametrize(
    "body",
    [
        "<html>网关错误</html>",
        '{"rows":[]}',
        '{"kbList":"unexpected"}',
        "[]",
    ],
)
def test_unparsable_response_is_a_failure_not_an_empty_schedule(body):
    crawler = _crawler([_FakeResponse(200, body), _FakeResponse(200, body)])

    with pytest.raises(NetworkError) as excinfo:
        _fetch(crawler)

    assert excinfo.value.code == "COURSE_FETCH_UNPARSABLE"


def test_non_200_status_is_a_failure_not_an_empty_schedule():
    crawler = _crawler([_FakeResponse(500, ""), _FakeResponse(502, "")])

    with pytest.raises(NetworkError) as excinfo:
        _fetch(crawler)

    assert "http_500" in str(excinfo.value)
    assert "http_502" in str(excinfo.value)


def test_desktop_success_short_circuits_mobile_fallback():
    crawler = _crawler([
        _FakeResponse(200, '{"kbList":[{"kcmc":"高等数学","xqj":1,"jc":"1-2节","zcd":"1-16周"}]}'),
    ])

    courses = _fetch(crawler)

    assert len(courses) == 1
    assert courses[0].name == "高等数学"
    assert crawler.client.calls == 1


def test_mobile_fallback_recovers_when_desktop_is_broken():
    crawler = _crawler([
        _FakeResponse(200, "<html>网关错误</html>"),
        _FakeResponse(200, '{"kbList":[{"kcmc":"大学英语","xqj":2,"jc":"3-4节","zcd":"1-8周"}]}'),
    ])

    courses = _fetch(crawler)

    assert [course.name for course in courses] == ["大学英语"]


def test_transport_exception_is_classified_as_failure():
    class _ExplodingClient:
        calls = 0

        async def post(self, *args, **kwargs):
            _ExplodingClient.calls += 1
            raise TimeoutError("connect timeout")

    crawler = EduCrawler.__new__(EduCrawler)
    crawler.client = _ExplodingClient()

    with pytest.raises(NetworkError) as excinfo:
        _fetch(crawler)

    assert "TimeoutError" in str(excinfo.value)


def test_uninitialised_client_still_raises_network_error():
    crawler = EduCrawler.__new__(EduCrawler)
    crawler.client = None

    with pytest.raises(NetworkError):
        _fetch(crawler)


# types 仅用于说明测试替身不依赖真实 httpx 客户端。
assert types is not None
