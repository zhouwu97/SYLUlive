"""
内部服务认证依赖 — 用于 Go → Python 的服务间调用

验证 Authorization: Bearer <token> 请求头。
使用 hmac.compare_digest 进行常量时间比较，防止时序攻击。

环境变量:
  INTERNAL_SERVICE_TOKEN: 高强度共享密钥
  未配置时拒绝所有请求（返回 503），不会发生空值匹配。
"""

import hmac
import os

from fastapi import Header, HTTPException, Request

# 延迟读取，允许模块导入后再设环境变量
_INTERNAL_SERVICE_TOKEN: str | None = None


def _load_token() -> str:
    """延迟加载 Token，避免模块导入时环境变量尚未设置。"""
    global _INTERNAL_SERVICE_TOKEN
    if _INTERNAL_SERVICE_TOKEN is None:
        _INTERNAL_SERVICE_TOKEN = os.getenv("INTERNAL_SERVICE_TOKEN", "")
    return _INTERNAL_SERVICE_TOKEN


async def verify_internal_token(
    request: Request,
    authorization: str = Header(default=""),
) -> None:
    """FastAPI 依赖：验证内部服务 Bearer Token。

    Args:
        request: FastAPI Request 对象
        authorization: Authorization 请求头

    Raises:
        HTTPException(503): Token 未配置
        HTTPException(401): Token 缺失或错误
    """
    token = _load_token()

    # 服务端未配置 Token → 503，拒绝全部请求
    if not token:
        raise HTTPException(
            status_code=503,
            detail="Internal service authentication is not configured",
        )

    # 检查 Bearer 前缀
    auth = authorization.strip()
    if not auth.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")

    provided = auth[len("Bearer "):]

    # 常量时间比较，防止时序攻击
    if not hmac.compare_digest(provided, token):
        raise HTTPException(status_code=401, detail="Invalid token")
