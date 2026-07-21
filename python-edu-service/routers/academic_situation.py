"""学业情况路由"""
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import AcademicSituationInput, AcademicSituationResponse
from services.crawler import (
    CookieLapseError,
    LoginFailedError,
    NetworkError,
)
from services.session import execute_with_session_refresh
from services.security import require_internal_service, require_internal_user

router = APIRouter(prefix="/api/edu/academic-situation", tags=["学业情况"], dependencies=[Depends(require_internal_service)])


@router.post("/", response_model=AcademicSituationResponse)
async def get_academic_situation(
    input: AcademicSituationInput,
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """获取官方学生学业情况。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == user_id))
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="请先绑定教务账号")

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定")

    try:
        payload = await execute_with_session_refresh(
            db=db,
            edu_user=edu_user,
            operation=lambda crawler, cookie: crawler.fetch_academic_situation(cookie),
            timeout=15.0,
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
    except Exception as e:
        return AcademicSituationResponse(
            success=False,
            error_code="ACADEMIC_SITUATION_PARSE_FAILED",
            courses_status="parse_failed",
            message=f"学业情况解析失败: {e}",
        )

    return AcademicSituationResponse(**payload)
