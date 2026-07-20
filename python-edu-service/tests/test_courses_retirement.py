"""验证退役课表缓存接口不再读取或写入服务器副本。"""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch):
    from routers import courses
    from services import security

    monkeypatch.setattr(security, "INTERNAL_SERVICE_TOKEN", "retirement-test-token")
    app = FastAPI()
    app.include_router(courses.router)
    return TestClient(app)


@pytest.mark.parametrize(
    ("method", "path", "payload"),
    [
        ("GET", "/api/edu/courses/local?year=2026&semester=3", None),
        (
            "POST",
            "/api/edu/courses/sync",
            {"year": "2026", "semester": 3, "raw_json": "[]"},
        ),
        ("POST", "/api/edu/courses/manual", {"custom_name": "课程"}),
        (
            "POST",
            "/api/edu/courses/customize/legacy-course",
            {"custom_name": "课程"},
        ),
        ("PUT", "/api/edu/courses/7", {"custom_name": "课程"}),
        ("DELETE", "/api/edu/courses/7", None),
    ],
)
def test_retired_course_cache_endpoints_return_upgrade_response(
    client, method, path, payload
):
    response = client.request(
        method,
        path,
        headers={"X-Internal-Service-Token": "retirement-test-token"},
        json=payload,
    )

    assert response.status_code == 410
    assert response.json() == {
        "code": "COURSE_CACHE_RETIRED",
        "error": "服务器课表缓存已退役，请升级客户端后重新同步课表",
        "action": "upgrade_client",
        "retryable": False,
    }


def test_retired_course_cache_endpoints_still_require_internal_auth(client):
    response = client.post("/api/edu/courses/sync", json={"raw_json": "[]"})

    assert response.status_code == 401
