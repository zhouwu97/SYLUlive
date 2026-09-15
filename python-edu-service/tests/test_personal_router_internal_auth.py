"""验证持有凭据的二课/爬虫路由不会成为无鉴权的凭据代理。

`routers/spider.py` 与 `routers/erke.py` 会代持学号 + 明文密码完成 WebVPN、
验证码 OCR 与二课登录，并把会话 Cookie 放进响应体。它们曾经是裸 router，
任何能访问端口的人都能借服务完成撞库与可用性探测，因此必须与 `/api/edu`
一致地走 `require_internal_service`（未配置密钥时 fail-closed 到 503）。
"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

TOKEN = "personal-router-test-token"


@pytest.fixture
def client(monkeypatch):
    from routers import erke, spider
    from services import security

    monkeypatch.setattr(security, "INTERNAL_SERVICE_TOKEN", TOKEN)
    app = FastAPI()
    app.include_router(spider.router)
    app.include_router(erke.router)
    return TestClient(app)


@pytest.mark.parametrize(
    ("path", "payload"),
    [
        ("/api/spider/erke", {"username": "2026000101", "password": "secret"}),
        ("/api/spider/erke/login", {"username": "2026000101", "password": "secret"}),
        (
            "/erke/scores",
            {
                "vpn_username": "vpn-user",
                "vpn_password": "vpn-secret",
                "erke_username": "2026000101",
                "erke_password": "erke-secret",
            },
        ),
    ],
)
def test_credential_proxy_routes_reject_missing_token(client, path, payload):
    response = client.post(path, json=payload)

    assert response.status_code == 401


def test_credential_proxy_routes_reject_wrong_token(client):
    response = client.post(
        "/erke/scores",
        headers={"X-Internal-Service-Token": "not-the-token"},
        json={},
    )

    assert response.status_code == 401


def test_credential_proxy_routes_fail_closed_without_configured_token(monkeypatch):
    from routers import erke
    from services import security

    monkeypatch.setattr(security, "INTERNAL_SERVICE_TOKEN", "")
    app = FastAPI()
    app.include_router(erke.router)

    response = TestClient(app).post("/erke/scores", json={})

    assert response.status_code == 503


def test_credential_proxy_routes_allow_authenticated_caller(client):
    """带正确密钥时应越过鉴权门禁，由参数校验接手（422 而非 401/403）。"""

    response = client.post(
        "/erke/scores",
        headers={"X-Internal-Service-Token": TOKEN},
        json={},
    )

    assert response.status_code == 422
