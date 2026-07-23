"""认证路由 - 绑定/解绑教务账号"""
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import AuthorizationCleanupInput, BindInput, BindResponse, UnbindResponse, EduStatusResponse, EduSessionResponse, ErrorResponse, PreVerifyResponse, PreVerifyInput, LoginEduInput, LoginEduResponse
from services.crawler import EduCrawler, CookieLapseError, LoginFailedError, NetworkError
from services.security import decrypt_credential, encrypt_credential, require_internal_service, require_internal_user

router = APIRouter(prefix="/api/edu", tags=["认证"], dependencies=[Depends(require_internal_service)])


def _error_code(exc: Exception) -> str:
    return getattr(exc, "code", "UNKNOWN_LOGIN_STATE")


def _error_detail(exc: Exception) -> dict:
    return {"code": _error_code(exc), "message": str(exc)}


def _session_response(edu_user: EduUser, message: str) -> EduSessionResponse:
    """将会话状态统一返回，避免旧 bound 字段承担多个语义。"""
    return EduSessionResponse(
        success=True,
        message=message,
        authorized=bool(edu_user.authorized),
        session_state=edu_user.session_state or "unbound",
        auto_relogin=bool(edu_user.auto_relogin),
    )


def _authorization_error(edu_user: EduUser | None) -> HTTPException:
    """按授权和会话状态返回可供 Go 层透传的稳定错误码。"""
    if not edu_user or not edu_user.authorized:
        return HTTPException(
            status_code=409,
            detail={"code": "EDU_AUTHORIZATION_REVOKED", "message": "教务授权已撤销，请重新授权"},
        )
    if edu_user.session_state == "logged_out":
        return HTTPException(
            status_code=409,
            detail={"code": "EDU_SESSION_LOGGED_OUT", "message": "教务会话已退出，请手动重新登录"},
        )
    if not edu_user.encrypted_password:
        return HTTPException(
            status_code=409,
            detail={"code": "EDU_CREDENTIAL_UNAVAILABLE", "message": "教务凭据不可用，请重新授权"},
        )
    return HTTPException(
        status_code=409,
        detail={"code": "EDU_SESSION_EXPIRED", "message": "教务会话已过期，请重新登录"},
    )


@router.post("/pre_verify", response_model=PreVerifyResponse)
async def pre_verify_edu_account(
    input: PreVerifyInput,
):
    """预验证教务账号（注册前验证学号和密码是否匹配）"""
    async with EduCrawler() as crawler:
        try:
            # 1. 尝试登录教务系统
            cookie = await crawler.login(input.student_id, input.password)

            # 2. 获取学生信息
            student_info = await crawler.get_student_info(cookie, input.student_id)

            return PreVerifyResponse(
                success=True,
                message="验证成功",
                student_id=input.student_id,
                name=student_info.name
            )

        except LoginFailedError as e:
            return PreVerifyResponse(
                success=False,
                message=str(e),
                code=_error_code(e),
            )
        except CookieLapseError as e:
            return PreVerifyResponse(
                success=False,
                message=str(e),
                code=_error_code(e),
            )
        except NetworkError as e:
            return PreVerifyResponse(
                success=False,
                message=str(e),
                code=_error_code(e),
            )
        except Exception as e:
            return PreVerifyResponse(
                success=False,
                message="教务验证失败，请稍后重试",
                code="UNKNOWN_LOGIN_STATE",
            )


@router.post("/bind", response_model=BindResponse)
async def bind_edu_account(
    input: BindInput,
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db)
):
    """绑定教务账号"""
    async with EduCrawler() as crawler:
        try:
            # 1. 登录教务系统
            cookie = await crawler.login(input.student_id, input.password)

            # 2. 获取学生信息
            student_info = await crawler.get_student_info(cookie, input.student_id)

            # 3. 在写入凭据前检查学号归属，数据库唯一索引仍是最终防线。
            result = await db.execute(
                select(EduUser).where(EduUser.user_id == user_id)
            )
            existing_user = result.scalar_one_or_none()

            owner_result = await db.execute(
                select(EduUser).where(
                    EduUser.student_id == input.student_id,
                    EduUser.user_id != user_id,
                )
            )
            if owner_result.scalar_one_or_none() is not None:
                raise HTTPException(
                    status_code=409,
                    detail={"code": "EDU_STUDENT_ALREADY_BOUND", "message": "该学号已绑定其他账号"},
                )

            if existing_user:
                if input.credential_generation <= existing_user.credential_generation:
                    raise HTTPException(
                        status_code=409,
                        detail={"code": "EDU_CREDENTIAL_GENERATION_STALE", "message": "教务授权请求已过期，请重试"},
                    )
                # 更新
                existing_user.student_id = input.student_id
                existing_user.name = student_info.name
                existing_user.encrypted_password = encrypt_credential(input.password)
                existing_user.raw_password = None
                existing_user.cookie = encrypt_credential(cookie)
                existing_user.grade = student_info.grade
                existing_user.college = student_info.college
                existing_user.major = student_info.major
                existing_user.bound = True
                existing_user.authorized = True
                existing_user.session_state = "active"
                existing_user.auto_relogin = True
                existing_user.authorized_at = existing_user.authorized_at or datetime.now()
                existing_user.logged_out_at = None
                existing_user.revoked_at = None
                existing_user.credential_generation = input.credential_generation
            else:
                # 新建
                edu_user = EduUser(
                    user_id=user_id,
                    student_id=input.student_id,
                    name=student_info.name,
                    encrypted_password=encrypt_credential(input.password),
                    cookie=encrypt_credential(cookie),
                    grade=student_info.grade,
                    college=student_info.college,
                    major=student_info.major,
                    bound=True,
                    authorized=True,
                    session_state="active",
                    auto_relogin=True,
                    authorized_at=datetime.now(),
                    credential_generation=input.credential_generation,
                )
                db.add(edu_user)

            await db.commit()

            return BindResponse(
                success=True,
                message="绑定成功",
                student_id=input.student_id,
                name=student_info.name,
                grade=student_info.grade,
                college=student_info.college,
                major=student_info.major
            )

        except HTTPException:
            await db.rollback()
            raise
        except LoginFailedError as e:
            raise HTTPException(status_code=401, detail=_error_detail(e))
        except CookieLapseError as e:
            raise HTTPException(status_code=401, detail=_error_detail(e))
        except NetworkError as e:
            raise HTTPException(status_code=503, detail=_error_detail(e))
        except Exception as e:
            await db.rollback()
            raise HTTPException(status_code=500, detail=f"绑定失败: {str(e)}")


@router.delete("/bind", response_model=EduSessionResponse)
async def unbind_edu_account(
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """兼容旧解绑路径：撤销授权，不释放稳定学号身份。"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user:
        return EduSessionResponse(
            success=True, message="未授权，无需撤销", authorized=False,
            session_state="revoked", auto_relogin=False,
        )

    edu_user.encrypted_password = None
    edu_user.raw_password = None
    edu_user.cookie = None
    edu_user.bound = False
    edu_user.authorized = False
    edu_user.session_state = "revoked"
    edu_user.auto_relogin = False
    edu_user.revoked_at = datetime.now()
    await db.commit()

    return _session_response(edu_user, "教务授权已撤销")


@router.get("/status", response_model=EduStatusResponse)
async def get_edu_status(
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db)
):
    """获取教务绑定状态"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user:
        return EduStatusResponse(bound=False)

    return EduStatusResponse(
        bound=bool(edu_user.authorized),
        authorized=bool(edu_user.authorized),
        session_state=edu_user.session_state or "unbound",
        auto_relogin=bool(edu_user.auto_relogin),
        student_id=edu_user.student_id,
        name=edu_user.name,
        grade=edu_user.grade,
        college=edu_user.college,
        major=edu_user.major
    )


@router.post("/refresh_cookie")
async def refresh_cookie(
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db)
):
    """刷新过期的Cookie"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.authorized or not edu_user.auto_relogin or edu_user.session_state == "logged_out":
        raise _authorization_error(edu_user)

    try:
        password = decrypt_credential(edu_user.encrypted_password)
    except (RuntimeError, ValueError):
        raise HTTPException(status_code=409, detail={"code": "EDU_CREDENTIAL_UNAVAILABLE", "message": "凭据已失效，请重新授权教务账号"})

    async with EduCrawler() as crawler:
        try:
            new_cookie = await crawler.login(edu_user.student_id, password)
            edu_user.cookie = encrypt_credential(new_cookie)
            edu_user.session_state = "active"
            await db.commit()
            return _session_response(edu_user, "教务会话已刷新")
        except (LoginFailedError, CookieLapseError, NetworkError) as e:
            raise HTTPException(status_code=401, detail=_error_detail(e))


@router.post("/session/logout", response_model=EduSessionResponse)
async def logout_edu_session(
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """只退出当前教务会话，保留授权凭据和已认证学生身份。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == user_id))
    edu_user = result.scalar_one_or_none()
    if not edu_user or not edu_user.authorized:
        raise _authorization_error(edu_user)

    edu_user.cookie = None
    edu_user.session_state = "logged_out"
    edu_user.auto_relogin = False
    edu_user.logged_out_at = datetime.now()
    await db.commit()
    return _session_response(edu_user, "已退出教务登录")


@router.post("/session/resume", response_model=EduSessionResponse)
async def resume_edu_session(
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """用户明确操作后，使用服务端加密凭据恢复教务会话。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == user_id))
    edu_user = result.scalar_one_or_none()
    if not edu_user or not edu_user.authorized or not edu_user.encrypted_password:
        raise _authorization_error(edu_user)
    try:
        password = decrypt_credential(edu_user.encrypted_password)
    except (RuntimeError, ValueError):
        raise HTTPException(status_code=409, detail={"code": "EDU_CREDENTIAL_UNAVAILABLE", "message": "凭据不可用，请重新授权教务账号"})

    async with EduCrawler() as crawler:
        try:
            cookie = await crawler.login(edu_user.student_id, password)
        except (LoginFailedError, CookieLapseError, NetworkError) as exc:
            raise HTTPException(status_code=401, detail=_error_detail(exc))
    edu_user.cookie = encrypt_credential(cookie)
    edu_user.session_state = "active"
    edu_user.auto_relogin = True
    edu_user.logged_out_at = None
    await db.commit()
    return _session_response(edu_user, "教务会话已恢复")


@router.delete("/authorization", response_model=EduSessionResponse)
async def revoke_edu_authorization(
    input: AuthorizationCleanupInput,
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """仅撤销指定代次的授权，旧任务不会删除重绑后的凭据。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == user_id))
    edu_user = result.scalar_one_or_none()
    if not edu_user or edu_user.credential_generation != input.expected_generation:
        return EduSessionResponse(
            success=True, message="旧教务清理任务已失效", authorized=False,
            session_state="revoked", auto_relogin=False,
        )
    if input.delete_identity:
        await db.delete(edu_user)
        await db.commit()
        return EduSessionResponse(
            success=True, message="教务身份与凭据已删除", authorized=False,
            session_state="revoked", auto_relogin=False,
        )
    edu_user.encrypted_password = None
    edu_user.raw_password = None
    edu_user.cookie = None
    edu_user.bound = False
    edu_user.authorized = False
    edu_user.session_state = "revoked"
    edu_user.auto_relogin = False
    edu_user.revoked_at = datetime.now()
    await db.commit()
    return _session_response(edu_user, "教务授权已撤销")


@router.post("/login_edu", response_model=LoginEduResponse)
async def login_edu_account(
    input: LoginEduInput,
):
    """统一登录（验证教务+获取信息，返回给Go服务器）"""
    async with EduCrawler() as crawler:
        try:
            # 1. 登录教务系统
            cookie = await crawler.login(input.student_id, input.edu_password)

            # 2. 获取学生信息
            student_info = await crawler.get_student_info(cookie, input.student_id)

            return LoginEduResponse(
                success=True,
                message="验证成功",
                student_id=input.student_id,
                name=student_info.name,
                grade=student_info.grade,
                college=student_info.college,
                major=student_info.major
            )

        except LoginFailedError as e:
            return LoginEduResponse(success=False, message=str(e), code=_error_code(e))
        except CookieLapseError as e:
            return LoginEduResponse(success=False, message=str(e), code=_error_code(e))
        except NetworkError as e:
            return LoginEduResponse(success=False, message=str(e), code=_error_code(e))
        except Exception as e:
            return LoginEduResponse(
                success=False,
                message="教务登录失败，请稍后重试",
                code="UNKNOWN_LOGIN_STATE",
            )
