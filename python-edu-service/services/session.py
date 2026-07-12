"""统一的教务会话刷新逻辑。

所有需要访问教务系统且可能遇到 Cookie 过期的路由,
通过 `execute_with_session_refresh` 复用同一套"检查→重登→重试→失败"流程,
并为每个用户提供 asyncio.Lock 避免并发重登风暴。
"""

import asyncio
import logging
from typing import Callable, Awaitable, TypeVar

from sqlalchemy.ext.asyncio import AsyncSession

from models.database import EduUser
from services.crawler import EduCrawler, CookieLapseError, LoginFailedError, NetworkError
from services.security import decrypt_credential, encrypt_credential

logger = logging.getLogger(__name__)

T = TypeVar("T")

_user_locks: dict[str, asyncio.Lock] = {}


def _user_lock(user_id: str) -> asyncio.Lock:
    lock = _user_locks.get(user_id)
    if lock is None:
        lock = asyncio.Lock()
        _user_locks[user_id] = lock
    return lock


async def execute_with_session_refresh(
    *,
    db: AsyncSession,
    edu_user: EduUser,
    operation: Callable[[EduCrawler, str], Awaitable[T]],
    timeout: float = 15.0,
) -> T:
    """在已登录的 EduCrawler 上下文中执行 operation,自动处理 Cookie 过期。

    operation(crawler, cookie) -> T

    会话刷新策略:
    1. 首次尝试使用数据库中的 Cookie
    2. CookieLapseError → 获取用户锁 → db.refresh 读取可能已被
       其他请求刷新的 Cookie → 再试一次 → 仍失败则重登并 db.commit
    3. 重试仍失败 → 抛出 CookieLapseError (上游转为 HTTP 401)

    锁内 commit 保证后续请求拿到的是最新 Cookie,避免并发重登风暴。
    """

    async def _attempt_fresh(cookie: str) -> T:
        async with EduCrawler(timeout=timeout) as crawler:
            try:
                return await operation(crawler, cookie)
            except CookieLapseError:
                raise
            except (LoginFailedError, NetworkError):
                raise

    try:
        original_cookie = decrypt_credential(edu_user.cookie)
    except (RuntimeError, ValueError) as exc:
        raise CookieLapseError("Cookie 已失效，请重新绑定教务账号") from exc

    # 首次尝试
    try:
        return await _attempt_fresh(original_cookie)
    except CookieLapseError:
        pass

    # 需要刷新 — 按用户串行化以避免并发重登
    lock = _user_lock(edu_user.user_id)
    async with lock:
        # 重新读取最新 Cookie（可能被前一个锁持有者刷新过）
        await db.refresh(edu_user)
        try:
            refreshed_cookie = decrypt_credential(edu_user.cookie)
        except (RuntimeError, ValueError):
            refreshed_cookie = ""
        if refreshed_cookie and refreshed_cookie != original_cookie:
            try:
                return await _attempt_fresh(refreshed_cookie)
            except CookieLapseError:
                pass

        try:
            password = decrypt_credential(edu_user.encrypted_password)
        except (RuntimeError, ValueError) as exc:
            raise CookieLapseError("Cookie 已失效，请重新绑定教务账号") from exc

        logger.info(
            "[EDU-SESSION] refreshing session user_id=%s student_id=%s",
            edu_user.user_id,
            getattr(edu_user, "student_id", ""),
        )

        try:
            async with EduCrawler(timeout=timeout) as login_crawler:
                new_cookie = await login_crawler.login(
                    edu_user.student_id, password,
                )
        except LoginFailedError as e:
            logger.warning(
                "[EDU-SESSION] re-login failed user_id=%s code=%s",
                edu_user.user_id,
                e.code,
            )
            raise CookieLapseError(
                f"账号密码可能已变更: {e}"
            ) from e

        # 锁内持久化，保证后续请求能看到最新 Cookie
        edu_user.cookie = encrypt_credential(new_cookie)
        await db.commit()
        await db.refresh(edu_user)
        refreshed_cookie = new_cookie

    # 重试（锁已释放，不阻塞其他用户）
    try:
        return await _attempt_fresh(refreshed_cookie)
    except CookieLapseError as e:
        raise CookieLapseError(
            "Cookie 已失效且自动登录失败，请重新绑定教务账号"
        ) from e
