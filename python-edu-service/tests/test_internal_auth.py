"""测试 internal_auth 依赖 — Token 验证逻辑。"""
import os
import pytest
from unittest.mock import patch, MagicMock

from fastapi import HTTPException


def _reload_auth_module():
    """重新加载 internal_auth 模块以刷新缓存 Token。"""
    import dependencies.internal_auth as mod
    import importlib
    importlib.reload(mod)
    return mod


class TestTokenMissing:
    """Token 未配置 → 503"""

    @pytest.mark.asyncio
    async def test_empty_token_env_returns_503(self):
        with pytest.raises(HTTPException) as exc:
            mod = _reload_auth_module()
            with patch.object(mod, "_INTERNAL_SERVICE_TOKEN", None):
                with patch.dict(os.environ, {"INTERNAL_SERVICE_TOKEN": ""}, clear=True):
                    mock_request = MagicMock()
                    await mod.verify_internal_token(
                        mock_request,
                        authorization="Bearer abc",
                    )
        assert exc.value.status_code == 503


class TestAuthHeaderMissing:
    """缺失 Authorization 头 → 401"""

    @pytest.mark.asyncio
    async def test_empty_header_returns_401(self):
        with pytest.raises(HTTPException) as exc:
            mod = _reload_auth_module()
            with patch.object(mod, "_INTERNAL_SERVICE_TOKEN", None):
                with patch.dict(os.environ, {"INTERNAL_SERVICE_TOKEN": "secret123"}):
                    mock_request = MagicMock()
                    await mod.verify_internal_token(
                        mock_request,
                        authorization="",
                    )
        assert exc.value.status_code == 401

    @pytest.mark.asyncio
    async def test_no_bearer_prefix_returns_401(self):
        with pytest.raises(HTTPException) as exc:
            mod = _reload_auth_module()
            with patch.object(mod, "_INTERNAL_SERVICE_TOKEN", None):
                with patch.dict(os.environ, {"INTERNAL_SERVICE_TOKEN": "secret123"}):
                    mock_request = MagicMock()
                    await mod.verify_internal_token(
                        mock_request,
                        authorization="secret123",
                    )
        assert exc.value.status_code == 401


class TestWrongToken:
    """错误 Token → 401"""

    @pytest.mark.asyncio
    async def test_wrong_token_returns_401(self):
        with pytest.raises(HTTPException) as exc:
            mod = _reload_auth_module()
            with patch.object(mod, "_INTERNAL_SERVICE_TOKEN", None):
                with patch.dict(os.environ, {"INTERNAL_SERVICE_TOKEN": "secret123"}):
                    mock_request = MagicMock()
                    await mod.verify_internal_token(
                        mock_request,
                        authorization="Bearer wrong_token",
                    )
        assert exc.value.status_code == 401


class TestCorrectToken:
    """正确 Token → 通过"""

    @pytest.mark.asyncio
    async def test_correct_token_passes(self):
        mod = _reload_auth_module()
        with patch.object(mod, "_INTERNAL_SERVICE_TOKEN", None):
            with patch.dict(os.environ, {"INTERNAL_SERVICE_TOKEN": "secret123"}):
                mock_request = MagicMock()
                # 不应抛出异常
                await mod.verify_internal_token(
                    mock_request,
                    authorization="Bearer secret123",
                )
