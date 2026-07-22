"""课程路由 - 仅允许本次按需提取，不持久化课程副本。"""

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import EduUser, get_db
from models.schemas import CourseFetchInput, CourseFetchResponse, CourseInfo
from services.crawler import (
    CookieLapseError,
    CourseNotOpenError,
    LoginFailedError,
    NetworkError,
    parse_time_sections,
    parse_weeks,
)
from services.security import require_internal_service, require_internal_user
from services.session import execute_with_session_refresh

router = APIRouter(
    prefix="/api/edu/courses",
    tags=["课程"],
    dependencies=[Depends(require_internal_service)],
)

_RETIRED_CACHE_CODE = "COURSE_CACHE_RETIRED"
_RETIRED_CACHE_MESSAGE = "服务器课表缓存已退役，请升级客户端后重新同步课表"


def _retired_course_cache_response() -> JSONResponse:
    """返回统一的旧客户端迁移响应，不读取或写入任何课程数据。"""
    return JSONResponse(
        status_code=410,
        content={
            "code": _RETIRED_CACHE_CODE,
            "error": _RETIRED_CACHE_MESSAGE,
            "action": "upgrade_client",
            "retryable": False,
        },
    )


@router.post("/fetch", response_model=CourseFetchResponse)
async def fetch_courses(
    input: CourseFetchInput,
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """从教务系统提取当前请求所需课表，不在服务端保存课程。"""
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.authorized:
        raise HTTPException(status_code=409, detail={"code": "EDU_AUTHORIZATION_REVOKED", "message": "教务授权已撤销，请重新授权"})
    if edu_user.session_state == "logged_out":
        raise HTTPException(status_code=409, detail={"code": "EDU_SESSION_LOGGED_OUT", "message": "教务会话已退出，请手动重新登录"})

    if not edu_user.cookie:
        raise HTTPException(status_code=401, detail={"code": "EDU_SESSION_EXPIRED", "message": "教务会话已过期，请重新登录"})

    try:
        raw_courses = await execute_with_session_refresh(
            db=db,
            edu_user=edu_user,
            operation=lambda crawler, cookie: crawler.fetch_courses(
                cookie, input.year, input.semester
            ),
        )
    except CookieLapseError as error:
        return JSONResponse(
            status_code=401,
            content={
                "code": getattr(error, "code", "SESSION_EXPIRED"),
                "error": str(error),
            },
        )
    except CourseNotOpenError as error:
        return CourseFetchResponse(
            success=False,
            year=input.year,
            semester=input.semester,
            courses=[],
            message=str(error),
        )
    except NetworkError as error:
        raise HTTPException(status_code=503, detail=str(error))
    except LoginFailedError as error:
        raise HTTPException(status_code=401, detail=str(error))

    # 仅记录数量，避免课程名称、教师、地点和周次进入服务端日志。
    print(f"[COURSES] fetched_count={len(raw_courses)}")
    courses = []
    for raw in raw_courses:
        start_section, end_section = parse_time_sections(raw.time)
        courses.append(
            CourseInfo(
                name=raw.name,
                teacher=raw.teacher or None,
                location=raw.location or None,
                time=start_section,
                end_time=end_section,
                week_day=int(raw.week_day) if raw.week_day.isdigit() else 1,
                weeks=parse_weeks(raw.week_str),
            )
        )

    return CourseFetchResponse(
        success=True,
        year=input.year,
        semester=input.semester,
        courses=courses,
        message=None,
    )


@router.post("/sync")
async def retired_sync_courses():
    """拒绝旧客户端上传课程副本。"""
    return _retired_course_cache_response()


@router.get("/local")
async def retired_local_courses():
    """拒绝读取历史服务器课表副本。"""
    return _retired_course_cache_response()


@router.post("/customize/{course_code}")
async def retired_customize_course(course_code: str):
    """拒绝旧课程自定义写入。"""
    del course_code
    return _retired_course_cache_response()


@router.post("/manual")
async def retired_manual_course():
    """拒绝旧手动课程写入。"""
    return _retired_course_cache_response()


@router.put("/{course_id}")
async def retired_update_course(course_id: int):
    """拒绝旧课程更新请求。"""
    del course_id
    return _retired_course_cache_response()


@router.delete("/{course_id}")
async def retired_delete_course(course_id: int):
    """拒绝旧课程删除请求。"""
    del course_id
    return _retired_course_cache_response()
