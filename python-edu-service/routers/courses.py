"""课程路由 - 课表提取、同步、管理"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, delete
from sqlalchemy.orm import selectinload
import json

from models.database import EduUser, CourseRaw, CourseCustom, get_db
from models.schemas import (
    CourseFetchInput, CourseFetchResponse, CourseInfo,
    CourseSyncInput, CourseSyncResponse,
    CourseCustomInput, CourseCustomResponse,
    LocalCourse, LocalCoursesResponse
)
from services.crawler import (
    EduCrawler, CookieLapseError, CourseNotOpenError,
    NetworkError, parse_weeks, time_to_section
)

router = APIRouter(prefix="/api/edu/courses", tags=["课程"])


def _generate_course_code(name: str, weekday: str, time: str) -> str:
    """生成课程代码（用于关联原始数据和自定义数据）"""
    import hashlib
    raw = f"{name}_{weekday}_{time}"
    return hashlib.md5(raw.encode()).hexdigest()[:12]


@router.post("/fetch", response_model=CourseFetchResponse)
async def fetch_courses(
    input: CourseFetchInput,
    db: AsyncSession = Depends(get_db)
):
    """从教务系统提取课表（返回原始数据供预览）"""
    # 验证用户绑定状态
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
            raw_courses = await crawler.fetch_courses(
                edu_user.cookie,
                input.year,
                input.semester
            )

            # 转换为CourseInfo列表
            courses = []
            for raw in raw_courses:
                course = CourseInfo(
                    name=raw.name,
                    teacher=raw.teacher if raw.teacher else None,
                    location=raw.location if raw.location else None,
                    time=time_to_section(raw.time),
                    week_day=int(raw.week_day) if raw.week_day.isdigit() else 1,
                    weeks=parse_weeks(raw.week_str)
                )
                courses.append(course)

            return CourseFetchResponse(
                success=True,
                year=input.year,
                semester=input.semester,
                courses=courses,
                message=None
            )

        except CookieLapseError:
            raise HTTPException(status_code=401, detail="Cookie已失效，请重新绑定教务账号")
        except CourseNotOpenError as e:
            return CourseFetchResponse(
                success=False,
                year=input.year,
                semester=input.semester,
                courses=[],
                message=str(e)
            )
        except NetworkError as e:
            raise HTTPException(status_code=503, detail=str(e))


@router.post("/sync", response_model=CourseSyncResponse)
async def sync_courses(
    input: CourseSyncInput,
    db: AsyncSession = Depends(get_db)
):
    """同步课表到本地（用户确认后）"""
    # 验证用户绑定
    result = await db.execute(
        select(EduUser).where(EduUser.user_id == input.user_id)
    )
    edu_user = result.scalar_one_or_none()

    if not edu_user or not edu_user.bound:
        raise HTTPException(status_code=400, detail="请先绑定教务账号")

    try:
        # 解析原始JSON
        raw_data = json.loads(input.raw_json)

        # 删除旧原始数据（如果有）
        await db.execute(
            delete(CourseRaw).where(
                CourseRaw.user_id == input.user_id,
                CourseRaw.year == input.year,
                CourseRaw.semester == input.semester
            )
        )

        # 删除旧自定义数据（如果有）
        await db.execute(
            delete(CourseCustom).where(CourseCustom.user_id == input.user_id)
        )

        # 存储原始数据
        course_raw = CourseRaw(
            user_id=input.user_id,
            year=input.year,
            semester=input.semester,
            raw_json=input.raw_json
        )
        db.add(course_raw)
        await db.flush()  # 获取ID

        # 处理自定义数据
        kb_list = raw_data.get("kbList", [])
        synced_count = 0

        for item in kb_list:
            name = item.get("kcmc", "")
            teacher = item.get("xm", "")
            location = item.get("cdmc", "")
            time_str = item.get("jc", "")
            weekday_str = item.get("xqj", "1")
            week_str = item.get("zcd", "")

            course_code = _generate_course_code(name, weekday_str, time_str)

            # 检查是否有用户自定义设置
            custom = next(
                (c for c in input.customizations if c.course_code == course_code),
                None
            )

            weekday = int(weekday_str) if weekday_str.isdigit() else 1
            start_section = time_to_section(time_str)

            # 解析周数
            weeks = parse_weeks(week_str)

            course_custom = CourseCustom(
                user_id=input.user_id,
                course_code=course_code,
                raw_id=course_raw.id,
                custom_name=custom.custom_name if custom else None,
                color=custom.color if custom and custom.color else "#4A90D9",
                location_custom=custom.location_custom if custom else None,
                note=custom.note if custom else None,
                class_duration=custom.class_duration if custom else 45,
                break_duration=custom.break_duration if custom else 10,
                weekday=weekday,
                start_section=start_section,
                end_section=start_section + 1,  # 默认两节课
                weeks=json.dumps(weeks),
                original_name=name,
                original_location=location,
                teacher=teacher
            )
            db.add(course_custom)
            synced_count += 1

        await db.commit()

        return CourseSyncResponse(
            success=True,
            message="同步成功",
            synced_count=synced_count
        )

    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="原始数据格式错误")
    except Exception as e:
        await db.rollback()
        raise HTTPException(status_code=500, detail=f"同步失败: {str(e)}")


@router.get("/local", response_model=LocalCoursesResponse)
async def get_local_courses(
    user_id: str,
    db: AsyncSession = Depends(get_db)
):
    """获取本地已美化课表"""
    result = await db.execute(
        select(CourseCustom).where(CourseCustom.user_id == user_id)
    )
    courses = result.scalars().all()

    local_courses = []
    for c in courses:
        # 确定显示的地点（优先自定义）
        location = c.location_custom if c.location_custom else c.original_location

        local_courses.append(LocalCourse(
            id=c.id,
            course_code=c.course_code,
            custom_name=c.custom_name,
            color=c.color,
            location=location,
            note=c.note,
            class_duration=c.class_duration,
            break_duration=c.break_duration,
            weekday=c.weekday,
            start_section=c.start_section,
            end_section=c.end_section,
            weeks=json.loads(c.weeks) if c.weeks else [],
            original_name=c.original_name,
            teacher=c.teacher
        ))

    return LocalCoursesResponse(courses=local_courses)


@router.put("/{course_id}", response_model=CourseCustomResponse)
async def update_course(
    course_id: int,
    input: CourseCustomInput,
    db: AsyncSession = Depends(get_db)
):
    """手动调整课程"""
    result = await db.execute(
        select(CourseCustom).where(CourseCustom.id == course_id)
    )
    course = result.scalar_one_or_none()

    if not course:
        raise HTTPException(status_code=404, detail="课程不存在")

    # 更新字段
    if input.custom_name is not None:
        course.custom_name = input.custom_name
    course.color = input.color
    if input.location_custom is not None:
        course.location_custom = input.location_custom
    if input.note is not None:
        course.note = input.note
    course.class_duration = input.class_duration
    course.break_duration = input.break_duration
    course.weekday = input.weekday
    course.start_section = input.start_section
    course.end_section = input.end_section
    course.weeks = json.dumps(input.weeks)

    await db.commit()
    await db.refresh(course)

    return CourseCustomResponse(
        id=course.id,
        course_code=course.course_code,
        custom_name=course.custom_name,
        color=course.color,
        location_custom=course.location_custom,
        note=course.note,
        class_duration=course.class_duration,
        break_duration=course.break_duration,
        weekday=course.weekday,
        start_section=course.start_section,
        end_section=course.end_section,
        weeks=json.loads(course.weeks) if course.weeks else [],
        original_name=course.original_name,
        original_location=course.original_location,
        teacher=course.teacher
    )


@router.delete("/{course_id}")
async def delete_course(
    course_id: int,
    db: AsyncSession = Depends(get_db)
):
    """删除课程"""
    result = await db.execute(
        select(CourseCustom).where(CourseCustom.id == course_id)
    )
    course = result.scalar_one_or_none()

    if not course:
        raise HTTPException(status_code=404, detail="课程不存在")

    await db.delete(course)
    await db.commit()

    return {"success": True, "message": "删除成功"}


@router.post("/customize/{course_code}")
async def customize_course(
    course_code: str,
    input: CourseCustomInput,
    db: AsyncSession = Depends(get_db)
):
    """为特定课程添加/更新自定义设置"""
    result = await db.execute(
        select(CourseCustom).where(
            CourseCustom.user_id == input.user_id,
            CourseCustom.course_code == course_code
        )
    )
    course = result.scalar_one_or_none()

    if not course:
        # 创建新的自定义课程
        course = CourseCustom(
            user_id=input.user_id,
            course_code=course_code,
            custom_name=input.custom_name,
            color=input.color,
            location_custom=input.location_custom,
            note=input.note,
            class_duration=input.class_duration,
            break_duration=input.break_duration,
            weekday=input.weekday,
            start_section=input.start_section,
            end_section=input.end_section,
            weeks=json.dumps(input.weeks)
        )
        db.add(course)
    else:
        # 更新
        course.custom_name = input.custom_name
        course.color = input.color
        course.location_custom = input.location_custom
        course.note = input.note
        course.class_duration = input.class_duration
        course.break_duration = input.break_duration
        course.weekday = input.weekday
        course.start_section = input.start_section
        course.end_section = input.end_section
        course.weeks = json.dumps(input.weeks)

    await db.commit()
    await db.refresh(course)

    return {"success": True, "message": "保存成功", "course_id": course.id}
