"""成绩路由"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from models.database import EduUser, get_db
from models.schemas import GradesInput, GradesResponse, GradeInfo
from services.crawler import EduCrawler, CookieLapseError, GradesNotOpenError, NetworkError

router = APIRouter(prefix="/api/edu/grades", tags=["成绩"])


@router.post("/", response_model=GradesResponse)
async def get_grades(
    input: GradesInput,
    db: AsyncSession = Depends(get_db)
):
    """获取成绩"""
    # 验证用户绑定
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == input.user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="请先绑定教务账号")

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定")

    async with EduCrawler() as crawler:
        try:
            raw_grades = await crawler.fetch_grades(
                edu_user.cookie,
                input.year,
                input.semester
            )

            # 转换为GradeInfo
            grades = []
            for item in raw_grades:
                grade_info = GradeInfo(
                    name=item.get("kcmc", ""),
                    class_id=item.get("jxb_id", ""),
                    teacher=item.get("jsxm", ""),
                    is_degree=item.get("sfxwkc", "") == "是",
                    credits=_parse_float(str(item.get("xf", "0"))),
                    gpa=_parse_float(str(item.get("jd", "0"))),
                    grade_points=_parse_float(str(item.get("xfjd", "0"))),
                    fraction=_parse_float(str(item.get("bfzcj", "0"))),
                    grade=item.get("cj", "")
                )
                grades.append(grade_info)

            return GradesResponse(
                success=True,
                year=input.year,
                semester=input.semester,
                grades=grades,
                message=None
            )

        except CookieLapseError:
            raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定教务账号")
        except GradesNotOpenError as e:
            return GradesResponse(
                success=False,
                year=input.year,
                semester=input.semester,
                grades=[],
                message=str(e)
            )
        except NetworkError as e:
            raise HTTPException(status_code=503, detail=str(e))


def _parse_float(value: str) -> float:
    """安全解析浮点数"""
    try:
        return float(value)
    except (ValueError, TypeError):
        return 0.0
