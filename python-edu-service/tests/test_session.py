import pytest
import asyncio
import base64
import os
from unittest.mock import AsyncMock, MagicMock, patch

from services.session import execute_with_session_refresh, CookieLapseError
from services.crawler import LoginFailedError, NetworkError
from models.database import EduUser
from services.security import encrypt_credential
from routers.auth import bind_edu_account, refresh_cookie, resume_edu_session
from fastapi import HTTPException
from models.schemas import BindInput

@pytest.fixture(autouse=True)
def _clear_locks(monkeypatch):
    from services.session import _user_locks
    # 使用独立的测试密钥，确保会话刷新只接受 AEAD 密文。
    monkeypatch.setattr("services.security.EDU_CREDENTIAL_ENCRYPTION_KEY", base64.urlsafe_b64encode(os.urandom(32)).decode())
    _user_locks.clear()
    yield

@pytest.mark.asyncio
async def test_session_refresh_success():
    """旧 Cookie 失败 → 自动登录成功 → 同一次请求直接返回"""
    mock_db = AsyncMock()
    mock_db.execute.return_value = MagicMock(rowcount=1)
    edu_user = EduUser(user_id="u1", student_id="s1", encrypted_password=encrypt_credential("p1"), cookie=encrypt_credential("old_cookie"), authorized=True, session_state="active", auto_relogin=True, credential_generation=1)

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
        assert edu_user.cookie != "new_cookie"
        assert operation.call_count == 2
        mock_crawler_instance.login.assert_called_once_with("s1", "p1")
        mock_db.commit.assert_awaited_once()

@pytest.mark.asyncio
async def test_session_refresh_login_failed():
    """明确密码错误 → EDU_INVALID_CREDENTIALS，提示重新输入密码"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", encrypted_password=encrypt_credential("p1"), cookie=encrypt_credential("old_cookie"), authorized=True, session_state="active", auto_relogin=True, credential_generation=1)

    operation = AsyncMock()
    operation.side_effect = [CookieLapseError("Expired")]

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()
        mock_crawler_instance.login.side_effect = LoginFailedError("用户名或密码错误", "INVALID_CREDENTIALS")
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        with pytest.raises(CookieLapseError, match="教务账号或密码错误"):
            await execute_with_session_refresh(
                db=mock_db,
                edu_user=edu_user,
                operation=operation
            )

        assert operation.call_count == 1
        mock_db.commit.assert_not_called()

@pytest.mark.asyncio
async def test_session_refresh_login_failed_invalid_credentials_code():
    """INVALID_CREDENTIALS 错误码必须是 EDU_INVALID_CREDENTIALS，供 Go 侧要求重输密码"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", encrypted_password=encrypt_credential("p1"), cookie=encrypt_credential("old_cookie"), authorized=True, session_state="active", auto_relogin=True, credential_generation=1)

    operation = AsyncMock()
    operation.side_effect = [CookieLapseError("Expired")]

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()
        mock_crawler_instance.login.side_effect = LoginFailedError("密码不正确", "INVALID_CREDENTIALS")
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        with pytest.raises(CookieLapseError) as exc_info:
            await execute_with_session_refresh(
                db=mock_db,
                edu_user=edu_user,
                operation=operation
            )

    assert exc_info.value.code == "EDU_INVALID_CREDENTIALS"

@pytest.mark.asyncio
async def test_session_refresh_login_cas_flow_changed_is_upstream_unavailable():
    """CAS/登录流程变化不是密码错误：保留密码、报上游暂时不可用"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", encrypted_password=encrypt_credential("p1"), cookie=encrypt_credential("old_cookie"), authorized=True, session_state="active", auto_relogin=True, credential_generation=1)

    operation = AsyncMock()
    operation.side_effect = [CookieLapseError("Expired")]

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()
        mock_crawler_instance.login.side_effect = LoginFailedError("登录页可能变化", "CAS_FLOW_CHANGED")
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        with pytest.raises(CookieLapseError) as exc_info:
            await execute_with_session_refresh(
                db=mock_db,
                edu_user=edu_user,
                operation=operation
            )

    assert exc_info.value.code == "EDU_UPSTREAM_UNAVAILABLE"
    assert "账号密码" not in str(exc_info.value)
    mock_db.commit.assert_not_called()

@pytest.mark.asyncio
async def test_session_refresh_login_network_error():
    """网络异常 → EDU_NETWORK_ERROR，不做凭据判断"""
    mock_db = AsyncMock()
    edu_user = EduUser(user_id="u1", student_id="s1", encrypted_password=encrypt_credential("p1"), cookie=encrypt_credential("old_cookie"), authorized=True, session_state="active", auto_relogin=True, credential_generation=1)

    operation = AsyncMock()
    operation.side_effect = [CookieLapseError("Expired")]

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        mock_crawler_instance = AsyncMock()
        mock_crawler_instance.login.side_effect = NetworkError("获取CSRF超时")
        MockCrawlerClass.return_value.__aenter__.return_value = mock_crawler_instance

        with pytest.raises(CookieLapseError) as exc_info:
            await execute_with_session_refresh(
                db=mock_db,
                edu_user=edu_user,
                operation=operation
            )

    assert exc_info.value.code == "EDU_NETWORK_ERROR"
    assert "教务系统网络异常" in str(exc_info.value)
    mock_db.commit.assert_not_called()

@pytest.mark.asyncio
async def test_session_refresh_concurrent_requests():
    """grades 和 academic-situation 同时触发 → 只登录一次，两个请求都成功"""
    mock_db = AsyncMock()
    mock_db.execute.return_value = MagicMock(rowcount=1)
    edu_user = EduUser(user_id="u1", student_id="s1", encrypted_password=encrypt_credential("p1"), cookie=encrypt_credential("old_cookie"), authorized=True, session_state="active", auto_relogin=True, credential_generation=1)

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
        assert edu_user.cookie != "new_cookie"


@pytest.mark.asyncio
async def test_session_refresh_does_not_restore_user_who_logged_out_while_waiting():
    """请求等待用户锁时若用户退出，持锁后的二次检查必须阻止静默登录。"""
    mock_db = AsyncMock()
    mock_db.execute.return_value = MagicMock(rowcount=1)
    edu_user = EduUser(
        id=1,
        user_id="u1",
        student_id="s1",
        encrypted_password=encrypt_credential("p1"),
        cookie=encrypt_credential("old_cookie"),
        authorized=True,
        session_state="active",
        auto_relogin=True,
        credential_generation=1,
    )

    async def refresh_after_logout(user):
        user.authorized = True
        user.session_state = "logged_out"
        user.auto_relogin = False

    mock_db.refresh.side_effect = refresh_after_logout
    operation = AsyncMock(side_effect=CookieLapseError("Expired"))

    with patch("services.session.EduCrawler") as MockCrawlerClass:
        with pytest.raises(CookieLapseError, match="教务会话已退出"):
            await execute_with_session_refresh(
                db=mock_db,
                edu_user=edu_user,
                operation=operation,
            )
        MockCrawlerClass.return_value.__aenter__.return_value.login.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize("endpoint", [resume_edu_session, refresh_cookie])
async def test_explicit_session_login_does_not_restore_cookie_after_revoke(endpoint):
    """外部登录期间若撤销已提交，resume 和 refresh 都必须丢弃新 Cookie。"""
    mock_db = AsyncMock()
    edu_user = EduUser(
        id=1,
        user_id="u1",
        student_id="s1",
        encrypted_password=encrypt_credential("p1"),
        cookie=None,
        authorized=True,
        session_state="expired",
        auto_relogin=True,
        credential_generation=3,
    )
    select_result = MagicMock()
    select_result.scalar_one_or_none.return_value = edu_user
    # 模拟撤销在 crawler.login 等待期间提交，条件 UPDATE 因 authorized=false 影响零行。
    mock_db.execute.side_effect = [select_result, MagicMock(rowcount=0)]

    with patch("routers.auth.EduCrawler") as MockCrawlerClass:
        crawler = AsyncMock()
        crawler.login.return_value = "new_cookie"
        MockCrawlerClass.return_value.__aenter__.return_value = crawler

        with pytest.raises(HTTPException) as exc_info:
            await endpoint("u1", mock_db)

    assert exc_info.value.status_code == 409
    assert exc_info.value.detail["code"] == "EDU_AUTHORIZATION_REVOKED"
    mock_db.rollback.assert_awaited_once()
    mock_db.commit.assert_not_awaited()


@pytest.mark.asyncio
async def test_bind_reuses_same_active_credential_generation_after_go_recovery():
    """Go 在 Python 已提交后崩溃时，同代次重试应直接恢复为成功。"""
    mock_db = AsyncMock()
    existing = EduUser(
        user_id="u1",
        student_id="2026000001",
        name="测试学生",
        grade="2026",
        college="计算机学院",
        major="软件工程",
        authorized=True,
        credential_generation=4,
    )
    existing_result = MagicMock()
    existing_result.scalar_one_or_none.return_value = existing
    owner_result = MagicMock()
    owner_result.scalar_one_or_none.return_value = None
    mock_db.execute.side_effect = [existing_result, owner_result]

    response = await bind_edu_account(
        BindInput(student_id="2026000001", password="edu-password", credential_generation=4),
        user_id="u1",
        db=mock_db,
    )

    assert response.success is True
    assert response.message == "绑定已恢复"
    assert response.student_id == "2026000001"
    mock_db.commit.assert_not_awaited()
