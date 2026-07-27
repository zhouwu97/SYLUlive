"""面向 Go 服务的教务聚合接口。"""

from typing import Any

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, model_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import EduUser, get_db
from models.schemas import (
    AcademicSituationResponse,
    CourseFetchResponse,
    CourseInfo,
    CreditRequirementResponse,
    GradeInfo,
    GradesResponse,
)
from services.crawler import (
    CookieLapseError,
    CourseNotOpenError,
    GradesNotOpenError,
    LoginFailedError,
    NetworkError,
    parse_time_sections,
    parse_weeks,
)
from services.security import require_internal_service, require_internal_user
from services.session import execute_with_session_refresh

router = APIRouter(
    prefix="/api/edu/context-bundle",
    tags=["教务聚合"],
    dependencies=[Depends(require_internal_service)],
)


class ContextBundleDataset(BaseModel):
    """单项抓取参数；不含 user_id，用户身份只来自内部请求头。"""

    model_config = ConfigDict(extra="forbid")

    type: str
    year: str | None = None
    semester: int | None = None

    @model_validator(mode="after")
    def validate_scope(self):
        if self.type in {"grades", "schedule"}:
            if not self.year or self.semester not in {3, 12}:
                raise ValueError(f"{self.type} 需要有效学年和学期")
        elif self.type in {"academic_situation", "credit_requirements"}:
            if self.year is not None or self.semester is not None:
                raise ValueError(f"{self.type} 不接受学期参数")
        else:
            raise ValueError(f"不支持的教务数据集: {self.type}")
        return self

    @property
    def key(self) -> str:
        if self.year is None:
            return self.type
        return f"{self.type}:{self.year}:{self.semester}"


class ContextBundleRequest(BaseModel):
    """聚合请求最多包含四个互不重复的数据集，防止无界教务刷新。"""

    model_config = ConfigDict(extra="forbid")

    datasets: list[ContextBundleDataset]

    @model_validator(mode="after")
    def validate_datasets(self):
        if not self.datasets or len(self.datasets) > 4:
            raise ValueError("datasets 数量必须在 1 到 4 之间")
        keys = [item.key for item in self.datasets]
        if len(keys) != len(set(keys)):
            raise ValueError("datasets 不允许重复")
        return self


@router.post("")
async def fetch_context_bundle(
    input: ContextBundleRequest,
    user_id: str = Depends(require_internal_user),
    db: AsyncSession = Depends(get_db),
):
    """按序抓取多个教务数据集，单项失败不会丢弃已完成结果。"""
    result = await db.execute(select(EduUser).where(EduUser.user_id == user_id))
    edu_user = result.scalar_one_or_none()
    if not edu_user or not edu_user.authorized:
        return _all_failed(input, "EDU_AUTHORIZATION_REVOKED", "教务授权已撤销，请重新授权")
    if edu_user.session_state == "logged_out":
        return _all_failed(input, "EDU_SESSION_LOGGED_OUT", "教务会话已退出，请手动恢复")
    if not edu_user.cookie:
        return _all_failed(input, "EDU_SESSION_EXPIRED", "教务会话已过期，请重新登录")

    results: dict[str, dict[str, Any]] = {}
    for dataset in input.datasets:
        results[dataset.key] = await _fetch_dataset(db, edu_user, dataset)
    return {
        "results": results,
        "partial": any(item["status"] != "success" for item in results.values()),
    }


async def _fetch_dataset(
    db: AsyncSession,
    edu_user: EduUser,
    dataset: ContextBundleDataset,
) -> dict[str, Any]:
    try:
        if dataset.type == "schedule":
            raw_courses = await execute_with_session_refresh(
                db=db,
                edu_user=edu_user,
                operation=lambda crawler, cookie: crawler.fetch_courses(
                    cookie, dataset.year, dataset.semester
                ),
            )
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
            return _success(
                CourseFetchResponse(
                    success=True,
                    year=dataset.year,
                    semester=dataset.semester,
                    courses=courses,
                ).model_dump(mode="json")
            )

        if dataset.type == "grades":
            raw_grades = await execute_with_session_refresh(
                db=db,
                edu_user=edu_user,
                operation=lambda crawler, cookie: crawler.fetch_grades(
                    cookie, dataset.year, dataset.semester
                ),
            )
            grades = [
                GradeInfo(
                    name=item.get("kcmc", ""),
                    course_id=item.get("kch_id", ""),
                    course_code=item.get("kch", ""),
                    class_id=item.get("jxb_id", ""),
                    student_grade_id=item.get("xh_id", ""),
                    teacher=item.get("jsxm", "") or None,
                    is_degree=item.get("sfxwkc", "") == "是",
                    credits=_parse_float(item.get("xf")),
                    gpa=_parse_float(item.get("jd")),
                    grade_points=_parse_float(item.get("xfjd")),
                    fraction=_parse_float(item.get("bfzcj")),
                    grade=item.get("cj", ""),
                    exam_type=_empty_to_none(item.get("ksxz")),
                    course_category=_empty_to_none(item.get("kklxdm")),
                    assessment_method=_empty_to_none(item.get("khfsmc")),
                )
                for item in raw_grades
            ]
            return _success(
                GradesResponse(
                    success=True,
                    year=dataset.year,
                    semester=dataset.semester,
                    grades=grades,
                ).model_dump(mode="json")
            )

        if dataset.type == "academic_situation":
            payload = await execute_with_session_refresh(
                db=db,
                edu_user=edu_user,
                operation=lambda crawler, cookie: crawler.fetch_academic_situation(cookie),
                timeout=15.0,
            )
            response = AcademicSituationResponse(**payload)
            if not response.success:
                return _failed(
                    response.error_code or "ACADEMIC_SITUATION_PARSE_FAILED",
                    response.message or "学业情况解析失败",
                )
            return _success(response.model_dump(mode="json"))

        payload = await execute_with_session_refresh(
            db=db,
            edu_user=edu_user,
            operation=lambda crawler, cookie: crawler.fetch_credit_requirements(cookie),
            timeout=20.0,
        )
        response = CreditRequirementResponse(**payload)
        if not response.success:
            return _failed(
                response.error_code or "CREDIT_REQUIREMENT_PARSE_FAILED",
                response.message or "学分要求解析失败",
            )
        return _success(response.model_dump(mode="json"))
    except CookieLapseError as error:
        return _failed(getattr(error, "code", "EDU_SESSION_EXPIRED"), str(error))
    except (CourseNotOpenError, GradesNotOpenError) as error:
        return _failed("EDU_DATA_NOT_OPEN", str(error))
    except NetworkError:
        return _failed("EDU_NETWORK_ERROR", "学校教务系统暂时不可用")
    except LoginFailedError as error:
        return _failed("EDU_LOGIN_FAILED", str(error))
    except Exception:
        # 不向 Go 暴露解析器内部异常、Cookie 或上游响应正文。
        return _failed("EDU_FETCH_FAILED", "教务数据抓取失败")


def _success(data: dict[str, Any]) -> dict[str, Any]:
    return {"status": "success", "data": data}


def _failed(error_code: str, message: str) -> dict[str, Any]:
    return {"status": "failed", "error_code": error_code, "message": message}


def _all_failed(input: ContextBundleRequest, error_code: str, message: str) -> dict[str, Any]:
    results = {item.key: _failed(error_code, message) for item in input.datasets}
    return {"results": results, "partial": True}


def _parse_float(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _empty_to_none(value: Any) -> str | None:
    text = str(value or "").strip()
    return text or None
