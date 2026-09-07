import base64
import json
from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from models.schemas import PreVerifyInput
from routers import auth
from services.crawler import EduCrawler, _looks_like_login_page


PROFILE = (
    Path(__file__).parent / "fixtures" / "profile" / "undergraduate_profile_verified.html"
).read_text(encoding="utf-8")
PROFILE_FOR_TEST = PROFILE.replace("TEST_STUDENT_ID", "TESTID0001")
LOGIN_PAGE = (
    '<form action="/xtgl/login_slogin.html">'
    '<input name="yhm"><input name="mm"></form>'
)


def _public_key_body() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = key.public_key().public_numbers()

    def encode(number: int) -> str:
        size = (number.bit_length() + 7) // 8
        return base64.b64encode(number.to_bytes(size, "big")).decode("ascii")

    return json.dumps({"modulus": encode(numbers.n), "exponent": encode(numbers.e)})


class _MockCrawler(EduCrawler):
    def __init__(self, handler):
        super().__init__(timeout=2)
        self._handler = handler

    async def __aenter__(self):
        self.client = httpx.AsyncClient(
            timeout=httpx.Timeout(2),
            follow_redirects=False,
            transport=httpx.MockTransport(self._handler),
            headers={"User-Agent": "test"},
        )
        return self

    async def __aexit__(self, *args):
        await self.client.aclose()


def _protocol_handler():
    state = {"warmed": False, "requests": []}
    key_body = _public_key_body()

    def handler(request: httpx.Request):
        path = request.url.path
        state["requests"].append((request.method, path))

        if path.endswith("/login_slogin.html") and request.method == "GET":
            if state["warmed"]:
                return httpx.Response(
                    302,
                    headers={"location": "/xtgl/index_initMenu.html"},
                    request=request,
                )
            return httpx.Response(
                200,
                text='<input id="csrftoken" name="csrftoken" value="TEST"/>',
                request=request,
            )
        if path.endswith("/login_getPublicKey.html"):
            return httpx.Response(200, text=key_body, request=request)
        if path.endswith("/login_slogin.html") and request.method == "POST":
            return httpx.Response(
                200,
                text="ok",
                headers={"set-cookie": "JSESSIONID=AUTH; Path=/"},
                request=request,
            )
        if path.endswith("/xsgrxxwh_cxXsgrxx.html"):
            if not state["warmed"]:
                return httpx.Response(200, text=LOGIN_PAGE, request=request)
            return httpx.Response(200, text=PROFILE_FOR_TEST, request=request)
        return httpx.Response(404, text="not found", request=request)

    def mark_warmed(request: httpx.Request):
        if request.url.path.endswith("/login_slogin.html") and request.method == "GET":
            # 第一次 GET 是取 CSRF，第二次 GET 才是登录后的续跳探活。
            if sum(1 for method, path in state["requests"] if method == "GET" and path.endswith("/login_slogin.html")) >= 1:
                state["warmed"] = True
        return handler(request)

    return mark_warmed, state


@pytest.mark.asyncio
async def test_pre_verify_reuses_post_login_continuation_before_profile(monkeypatch):
    handler, state = _protocol_handler()
    monkeypatch.setattr(auth, "EduCrawler", lambda: _MockCrawler(handler))

    response = await auth.pre_verify_edu_account(
        PreVerifyInput(student_id="TESTID0001", password="test-password")
    )

    assert response.success is True
    assert response.school_verified_student_id == "TESTID0001"
    paths = [path for _, path in state["requests"]]
    assert paths == [
        "/xtgl/login_slogin.html",
        "/xtgl/login_getPublicKey.html",
        "/xtgl/login_slogin.html",
        "/xtgl/login_slogin.html",
        "/xsxxxggl/xsgrxxwh_cxXsgrxx.html",
        "/xsxxxggl/xsgrxxwh_cxXsgrxx.html",
    ]


def test_login_detector_does_not_treat_profile_script_as_login_page():
    profile_with_navigation_script = PROFILE.replace(
        "</body>", '<script>const help = "login_slogin.html";</script></body>'
    )

    assert _looks_like_login_page(profile_with_navigation_script) is False
    assert _looks_like_login_page(LOGIN_PAGE) is True
    assert _looks_like_login_page("<title>统一身份认证</title><form></form>") is True
    assert _looks_like_login_page("<p>用户登录</p>") is False


def test_cookie_string_is_path_aware_for_duplicate_session_cookie_names():
    crawler = EduCrawler()
    client = httpx.Client()
    client.cookies.set("JSESSIONID", "ROOT", domain="jxw.sylu.edu.cn", path="/")
    client.cookies.set("JSESSIONID", "XTGL", domain="jxw.sylu.edu.cn", path="/xtgl")
    crawler.client = client

    try:
        login_cookie = crawler._cookie_string("https://jxw.sylu.edu.cn/xtgl/login_slogin.html")
        profile_cookie = crawler._cookie_string(
            "https://jxw.sylu.edu.cn/xsxxxggl/xsgrxxwh_cxXsgrxx.html"
        )
    finally:
        client.close()

    assert login_cookie == "JSESSIONID=XTGL; JSESSIONID=ROOT"
    assert profile_cookie == "JSESSIONID=ROOT"


@pytest.mark.asyncio
async def test_pre_verify_unexpected_exception_log_contains_only_stage_and_type(
    monkeypatch, caplog
):
    class _BrokenCrawler:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def login(self, student_id, password):
            raise RuntimeError("sensitive response text must not be logged")

    monkeypatch.setattr(auth, "EduCrawler", _BrokenCrawler)
    with caplog.at_level("WARNING", logger=auth.logger.name):
        response = await auth.pre_verify_edu_account(
            PreVerifyInput(student_id="TESTID0001", password="test-password")
        )

    assert response.success is False
    assert response.code == "UNKNOWN_LOGIN_STATE"
    assert "stage=pre_verify" in caplog.text
    assert "exception_type=RuntimeError" in caplog.text
    assert "sensitive response text" not in caplog.text


@pytest.mark.asyncio
@pytest.mark.parametrize("error_type", [httpx.ConnectError, httpx.ReadTimeout])
async def test_pre_verify_maps_httpx_transport_failures_to_network_code(
    monkeypatch, caplog, error_type
):
    class _TransportFailureCrawler:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def login(self, student_id, password):
            raise error_type("network detail must not be returned")

    monkeypatch.setattr(auth, "EduCrawler", _TransportFailureCrawler)
    with caplog.at_level("WARNING", logger=auth.logger.name):
        response = await auth.pre_verify_edu_account(
            PreVerifyInput(student_id="TESTID0001", password="test-password")
        )

    assert response.success is False
    assert response.code == "REMOTE_SYSTEM_UNAVAILABLE"
    assert response.message == "教务系统暂时不可用，请稍后重试"
    assert "category=network" in caplog.text
    assert f"exception_type={error_type.__name__}" in caplog.text
    assert "network detail must not be returned" not in caplog.text
