"""学校个人能力退役路由的进程级集成测试。"""

from __future__ import annotations

from fastapi.testclient import TestClient
from starlette.requests import Request

import main


RETIRED_ROUTES = (
    ("/api/login_edu", "LEGACY_EDU_ROUTE_RETIRED"),
    ("/api/register_with_edu", "LEGACY_EDU_ROUTE_RETIRED"),
    ("/api/password/edu/reset", "LEGACY_EDU_ROUTE_RETIRED"),
    ("/api/personal-snapshots/erke", "SCHOOL_ACADEMIC_ROUTE_RETIRED"),
    ("/api/edu", "SCHOOL_ACADEMIC_ROUTE_RETIRED"),
    ("/api/edu/bind", "SCHOOL_ACADEMIC_ROUTE_RETIRED"),
    ("/api/login_edu/", "LEGACY_EDU_ROUTE_RETIRED"),
    ("/api/personal-snapshots/erke/", "SCHOOL_ACADEMIC_ROUTE_RETIRED"),
    ("/api/edu/grades/detail", "SCHOOL_ACADEMIC_ROUTE_RETIRED"),
)


def test_retired_routes_return_410_without_reading_body(monkeypatch) -> None:
    async def reject_body_read(_request: Request) -> bytes:
        raise AssertionError("退役路由不得读取请求 Body")

    monkeypatch.setattr(Request, "body", reject_body_read)
    client = TestClient(main.create_app(retired=True))

    for path, code in RETIRED_ROUTES:
        for method in ("GET", "POST", "PUT", "PATCH", "DELETE"):
            response = client.request(
                method,
                path,
                content=b"{",
                headers={
                    "Authorization": "Bearer invalid-token-must-not-be-checked",
                    "Content-Type": "application/json",
                },
            )
            assert response.status_code == 410
            assert response.json()["code"] == code
            assert response.headers["cache-control"] == "no-store"
            assert response.headers["sunset"] == "true"


def test_application_factory_captures_retirement_state(monkeypatch) -> None:
    """改变环境变量后创建的新实例不复用导入时的路由状态。"""

    monkeypatch.setenv("SCHOOL_AUTHORITY_RETIRED", "true")
    retired_app = main.create_app()
    monkeypatch.setenv("SCHOOL_AUTHORITY_RETIRED", "false")
    active_app = main.create_app()

    assert retired_app.state.school_authority_retired is True
    assert active_app.state.school_authority_retired is False
    retired_paths = {route.path for route in retired_app.routes}
    active_paths = {route.path for route in active_app.routes}
    assert "/api/edu/bind" not in retired_paths
    assert "/api/edu/bind" in active_paths


def test_retirement_does_not_block_public_service_routes() -> None:
    client = TestClient(main.create_app(retired=True))

    assert client.get("/health").status_code == 200
    assert client.get("/").status_code == 200
