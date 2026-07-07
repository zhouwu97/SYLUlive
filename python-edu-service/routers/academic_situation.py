"""学业情况路由"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import AcademicSituationInput, AcademicSituationResponse
from services.crawler import (
    CookieLapseError,
    EduCrawler,
    LoginFailedError,
    NetworkError,
)

router = APIRouter(prefix="/api/edu/academic-situation", tags=["学业情况"])


@router.post("/", response_model=AcademicSituationResponse)
async def get_academic_situation(
    input: AcademicSituationInput,
    db: AsyncSession = Depends(get_db),
):
    """获取官方学生学业情况。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == input.user_id))
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="请先绑定教务账号")

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定")

    async with EduCrawler(timeout=15.0) as crawler:
        cookie = edu_user.cookie

        for attempt in range(2):
            try:
                payload = await crawler.fetch_academic_situation(cookie)
            except CookieLapseError:
                if attempt == 1:
                    raise HTTPException(status_code=401, detail="Cookie已失效且自动登录失败，请重新绑定教务账号")
                if not edu_user.raw_password:
                    raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定教务账号")
                try:
                    cookie = await crawler.login(edu_user.student_id, edu_user.raw_password)
                    edu_user.cookie = cookie
                    await db.commit()
                except LoginFailedError as e:
                    raise HTTPException(status_code=401, detail=f"账号密码可能已变更: {e}")
                continue
            except NetworkError as e:
                raise HTTPException(status_code=503, detail=str(e))
            except Exception as e:
                return AcademicSituationResponse(success=False, message=f"学业情况解析失败: {e}")
            break

        return AcademicSituationResponse(**payload)
