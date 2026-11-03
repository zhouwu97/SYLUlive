from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from models.schemas import SessionVerifyInput
from routers import auth
from services import security
from services.crawler import EduCrawler, LoginFailedError


@pytest.mark.asyncio
async def test_session_probe_only_contacts_fixed_school_and_ignores_caller_identity():
    requests = []
    html = (Path(__file__).parent / "fixtures/profile/undergraduate_profile_verified.html").read_text(encoding="utf-8")
    def respond(request):
        requests.append(request)
        return httpx.Response(200, text=html)
    crawler = EduCrawler()
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond), follow_redirects=False) as client:
        crawler.client = client
        assert await crawler.verify_session_student_id("SID=fixture") == "TEST_STUDENT_ID"
    assert requests[0].url.host == "jxw.sylu.edu.cn"
    assert "su" not in requests[0].url.params
    assert "student_id" not in requests[0].url.params
    assert requests[0].headers["Cookie"] == "SID=fixture"


@pytest.mark.asyncio
@pytest.mark.parametrize("html", ["<html>登录</html>", '<input id="xh_id" value="forged">', '<div id="col_xh">X</div><input id="xh_id" value="Y"><input id="curXh_id" value="X">'])
async def test_session_probe_rejects_missing_or_conflicting_school_identity(html):
    crawler = EduCrawler()
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, text=html))) as client:
        crawler.client = client
        with pytest.raises(LoginFailedError):
            await crawler.verify_session_student_id("SID=fake")


def test_secret_session_is_redacted_and_extra_identity_is_rejected():
    assert "fixture-secret" not in repr(SessionVerifyInput(cookie="SID=fixture-secret"))
    with pytest.raises(ValueError):
        SessionVerifyInput(cookie="SID=fixture", student_id="forged")


def test_internal_session_endpoint_requires_service_token(monkeypatch):
    monkeypatch.setattr(security, "INTERNAL_SERVICE_TOKEN", "fixture-token")
    app = FastAPI()
    app.include_router(auth.router)
    client = TestClient(app)
    assert client.post("/api/edu/verify_session", json={"cookie": "SID=fake"}).status_code == 401
