import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from models.schemas import CourseFetchInput
from routers import courses
from services.crawler import CookieLapseError


@pytest.mark.asyncio
async def test_expired_session_response_does_not_expose_exception(monkeypatch):
    user = SimpleNamespace(authorized=True, session_state="active", cookie="test-cookie")
    db = SimpleNamespace(execute=AsyncMock(return_value=SimpleNamespace(scalar_one_or_none=lambda: user)))
    monkeypatch.setattr(courses, "execute_with_session_refresh", AsyncMock(side_effect=CookieLapseError("secret-cookie internal traceback")))
    response = await courses.fetch_courses(CourseFetchInput(user_id="test", year="2026", semester=3), "test", db)
    assert response.status_code == 401
    body = json.loads(response.body)
    assert "secret-cookie" not in body["error"]
    assert "traceback" not in body["error"]
    assert body["code"] == "SESSION_EXPIRED"
