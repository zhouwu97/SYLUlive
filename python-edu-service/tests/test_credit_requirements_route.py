"""学分要求路由的异常边界测试。"""

from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock

import pytest
from fastapi import HTTPException

from models.schemas import CreditRequirementInput
from routers import credit_requirements


@pytest.mark.asyncio
async def test_unexpected_failure_uses_sanitized_http_500(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """内部异常必须记录日志并转换为稳定的非 200 响应。"""
    db = AsyncMock()
    query_result = Mock()
    query_result.scalar_one_or_none.return_value = SimpleNamespace(
        authorized=True,
        session_state="active",
        cookie="session-cookie",
    )
    db.execute.return_value = query_result

    async def raise_unexpected(**_kwargs: object) -> None:
        raise RuntimeError("upstream body leaked: /private/path")

    monkeypatch.setattr(
        credit_requirements,
        "execute_with_session_refresh",
        raise_unexpected,
    )

    with pytest.raises(HTTPException) as exc_info:
        await credit_requirements.get_credit_requirements(
            CreditRequirementInput(user_id="ignored"),
            user_id="test-user",
            db=db,
        )

    assert exc_info.value.status_code == 500
    assert exc_info.value.detail == {
        "code": "CREDIT_REQUIREMENT_INTERNAL_ERROR",
        "message": "学分要求服务处理失败，请稍后重试",
    }
    assert "upstream body leaked" not in str(exc_info.value.detail)
    assert "[EDU-CREDIT-REQ] unexpected failure" in caplog.text
