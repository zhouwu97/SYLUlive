"""成绩路由"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import (
    GradeDetailInput,
    GradeDetailResponse,
    GradeInfo,
    GradesInput,
    GradesResponse,
)
from services.crawler import EduCrawler, CookieLapseError, GradesNotOpenError, NetworkError, LoginFailedError

router = APIRouter(prefix="/api/edu/grades", tags=["成绩"])


@router.post("/", response_model=GradesResponse)
async def get_grades(
    input: GradesInput,
    db: AsyncSession = Depends(get_db)
):
    """获取成绩"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == input.user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="请先绑定教务账号")

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定")

    async with EduCrawler() as crawler:
        cookie = edu_user.cookie

        for attempt in range(2):
            try:
                raw_grades = await crawler.fetch_grades(cookie, input.year, input.semester)
            except CookieLapseError:
                if attempt == 1:
                    raise HTTPException(status_code=401, detail="Cookie已失效且自动登录失败，请重新绑定教务账号")
                if not edu_user.raw_password:
                    raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定教务账号")
                print(f"  [AUTO] Cookie过期，使用存储密码自动重新登录...")
                try:
                    cookie = await crawler.login(edu_user.student_id, edu_user.raw_password)
                    edu_user.cookie = cookie
                    await db.commit()
                    print(f"  [AUTO] 重新登录成功，重试抓取成绩...")
                except LoginFailedError as e:
                    raise HTTPException(status_code=401, detail=f"账号密码可能已变更: {e}")
                continue
            except GradesNotOpenError as e:
                return GradesResponse(success=False, year=input.year, semester=input.semester, grades=[], message=str(e))
            except NetworkError as e:
                raise HTTPException(status_code=503, detail=str(e))
            break

        # 转换为GradeInfo
        grades = []
        for item in raw_grades:
            grade_info = GradeInfo(
                name=item.get("kcmc", ""),
                course_id=item.get("kch_id", ""),
                course_code=item.get("kch", ""),
                class_id=item.get("jxb_id", ""),
                student_grade_id=item.get("xh_id", ""),
                teacher=item.get("jsxm", ""),
                is_degree=item.get("sfxwkc", "") == "是",
                credits=_parse_float(str(item.get("xf", "0"))),
                gpa=_parse_float(str(item.get("jd", "0"))),
                grade_points=_parse_float(str(item.get("xfjd", "0"))),
                fraction=_parse_float(str(item.get("bfzcj", "0"))),
                grade=item.get("cj", ""),
                exam_type=_empty_to_none(item.get("ksxz")),
                course_category=_empty_to_none(item.get("kklxdm")),
                assessment_method=_empty_to_none(item.get("khfsmc")),
            )
            grades.append(grade_info)

        return GradesResponse(
            success=True, year=input.year, semester=input.semester,
            grades=grades, message=None
        )


@router.post("/detail", response_model=GradeDetailResponse)
async def get_grade_detail(
    input: GradeDetailInput,
    db: AsyncSession = Depends(get_db)
):
    """获取单门课程成绩构成"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == input.user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="请先绑定教务账号")

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定")

    async with EduCrawler() as crawler:
        cookie = edu_user.cookie

        for attempt in range(2):
            try:
                detail = await crawler.fetch_grade_detail(
                    cookie=cookie,
                    year=input.year,
                    semester=input.semester,
                    class_id=input.class_id,
                    course_name=input.course_name,
                    course_id=input.course_id,
                    student_grade_id=input.student_grade_id,
                )
            except CookieLapseError:
                if attempt == 1:
                    raise HTTPException(status_code=401, detail="Cookie已失效且自动登录失败，请重新绑定教务账号")
                if not edu_user.raw_password:
                    raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定教务账号")
                print(f"  [AUTO] Cookie过期，使用存储密码自动重新登录...")
                try:
                    cookie = await crawler.login(edu_user.student_id, edu_user.raw_password)
                    edu_user.cookie = cookie
                    await db.commit()
                    print(f"  [AUTO] 重新登录成功，重试抓取成绩明细...")
                except LoginFailedError as e:
                    raise HTTPException(status_code=401, detail=f"账号密码可能已变更: {e}")
                continue
            except NetworkError as e:
                raise HTTPException(status_code=503, detail=str(e))
            break

        return GradeDetailResponse(**detail)


def _parse_float(value: str) -> float:
    """安全解析浮点数"""
    try:
        return float(value)
    except (ValueError, TypeError):
        return 0.0


def _empty_to_none(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
