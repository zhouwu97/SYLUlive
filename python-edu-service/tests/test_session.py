import pytest
import asyncio
from unittest.mock import AsyncMock, patch

from services.session import execute_with_session_refresh, CookieLapseError
from services.crawler import LoginFailedError
from models.database import EduUser

@pytest.fixture(autouse=True)
def _clear_locks():
    from services.session import _user_locks
    _user_locks.clear()
    yield

@pytest.mark.asyncio
async def test_session_refresh_success():
    """旧 Cookie 失败 → 自动登录成功 → 同一次请求直接返回"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", raw_password="p1", cookie="old_cookie")

    operation = AsyncMock()
    operation.side_effect = [CookieLapseError("Expired"), "success_data"]

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()
        mock_crawler_instance.login.return_value = "new_cookie"
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        result = await execute_with_session_refresh(
            db=mock_db,
            edu_user=edu_user,
            operation=operation
        )

        assert result == "success_data"
        assert edu_user.cookie == "new_cookie"
        assert operation.call_count == 2
        mock_crawler_instance.login.assert_called_once_with("s1", "p1")
        mock_db.commit.assert_awaited_once()

@pytest.mark.asyncio
async def test_session_refresh_login_failed():
    """旧 Cookie 失败 → 登录失败 → 返回 CookieLapseError"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", raw_password="p1", cookie="old_cookie")

    operation = AsyncMock()
    operation.side_effect = [CookieLapseError("Expired")]

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()
        mock_crawler_instance.login.side_effect = LoginFailedError("Wrong pass", "401")
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        with pytest.raises(CookieLapseError, match="账号密码可能已变更"):
            await execute_with_session_refresh(
                db=mock_db,
                edu_user=edu_user,
                operation=operation
            )

        assert operation.call_count == 1
        mock_db.commit.assert_not_called()

@pytest.mark.asyncio
async def test_session_refresh_concurrent_requests():
    """grades 和 academic-situation 同时触发 → 只登录一次，两个请求都成功"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", raw_password="p1", cookie="old_cookie")

    op1 = AsyncMock()
    op2 = AsyncMock()

    async def op1_side_effect(crawler, cookie):
        if cookie == "old_cookie":
            raise CookieLapseError("Expired")
        return "result_grades"

    async def op2_side_effect(crawler, cookie):
        if cookie == "old_cookie":
            raise CookieLapseError("Expired")
        return "result_academic"

    op1.side_effect = op1_side_effect
    op2.side_effect = op2_side_effect

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()

        async def mock_login(student_id, pwd):
            await asyncio.sleep(0.1)  # Simulate network delay so R2 waits on lock
            return "new_cookie"

        mock_crawler_instance.login.side_effect = mock_login
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        # Start both requests concurrently
        t1 = asyncio.create_task(execute_with_session_refresh(db=mock_db, edu_user=edu_user, operation=op1))
        t2 = asyncio.create_task(execute_with_session_refresh(db=mock_db, edu_user=edu_user, operation=op2))

        results = await asyncio.gather(t1, t2)

        assert set(results) == {"result_grades", "result_academic"}
        # 确保只调用了一次 login
        assert mock_crawler_instance.login.call_count == 1
        assert edu_user.cookie == "new_cookie"
