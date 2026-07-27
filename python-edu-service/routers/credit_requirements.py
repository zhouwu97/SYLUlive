"""学分要求路由"""
import logging

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import CreditRequirementInput, CreditRequirementResponse
from services.crawler import (
    CookieLapseError,
    LoginFailedError,
    NetworkError,
)
from services.session import execute_with_session_refresh
from services.security import require_internal_service, require_internal_user

router = APIRouter(prefix="/api/edu/credit-requirements", tags=["学分要求"], dependencies=[Depends(require_internal_service)])
logger = logging.getLogger(__name__)


@router.post("/", response_model=CreditRequirementResponse)
async def get_credit_requirements(
    input: CreditRequirementInput,
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """获取官方学分要求/学籍预警数据。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == user_id))
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.authorized:
        raise HTTPException(status_code=409, detail={"code": "EDU_AUTHORIZATION_REVOKED", "message": "教务授权已撤销，请重新授权"})
    if edu_user.session_state == "logged_out":
        raise HTTPException(status_code=409, detail={"code": "EDU_SESSION_LOGGED_OUT", "message": "教务会话已退出，请手动重新登录"})

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail={"code": "EDU_SESSION_EXPIRED", "message": "教务会话已过期，请重新登录"})

    try:
        payload = await execute_with_session_refresh(
            db=db,
            edu_user=edu_user,
            operation=lambda crawler, cookie: crawler.fetch_credit_requirements(cookie),
            timeout=20.0,
        )
    except CookieLapseError as e:
        return JSONResponse(
            status_code=401,
            content={
                "code": getattr(e, "code", "SESSION_EXPIRED"),
                "error": str(e),
            },
        )
    except NetworkError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except LoginFailedError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except Exception:
        # 详细异常仅保留在服务端日志，避免泄露上游响应、路径或内部实现。
        logger.exception("[EDU-CREDIT-REQ] unexpected failure")
        raise HTTPException(
            status_code=500,
            detail={
                "code": "CREDIT_REQUIREMENT_INTERNAL_ERROR",
                "message": "学分要求服务处理失败，请稍后重试",
            },
        )

    return CreditRequirementResponse(**payload)
