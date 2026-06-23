"""Pydantic 数据模型"""
from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime


# ============== 认证相关 ==============

class BindInput(BaseModel):
    """绑定教务账号输入"""
    user_id: str = Field(..., description="App用户ID")
    student_id: str = Field(..., min_length=10, max_length=10, description="学号")
    password: str = Field(..., description="教务密码")


class BindResponse(BaseModel):
    """绑定响应"""
    success: bool
    message: str
    student_id: str
    cookie: Optional[str] = None  # 登录Cookie，供Go服务器存储
    name: Optional[str] = None
    grade: Optional[str] = None
    college: Optional[str] = None
    major: Optional[str] = None


class UnbindResponse(BaseModel):
    """解绑响应"""
    success: bool
    message: str


class EduStatusResponse(BaseModel):
    """教务绑定状态"""
    bound: bool
    student_id: Optional[str] = None
    name: Optional[str] = None
    grade: Optional[str] = None
    college: Optional[str] = None
    major: Optional[str] = None


class PreVerifyInput(BaseModel):
    """预验证教务账号输入"""
    student_id: str = Field(..., min_length=10, max_length=10, description="学号")
    password: str = Field(..., description="教务密码")


class PreVerifyResponse(BaseModel):
    """预验证响应"""
    success: bool
    message: str
    student_id: Optional[str] = None
    name: Optional[str] = None


class LoginEduInput(BaseModel):
    """统一登录输入"""
    student_id: str = Field(..., min_length=10, max_length=10, description="学号")
    edu_password: str = Field(..., description="教务密码")
    password: str = Field(..., min_length=8, max_length=32, description="APP密码")


class LoginEduResponse(BaseModel):
    """统一登录响应"""
    success: bool
    message: str
    student_id: Optional[str] = None
    name: Optional[str] = None
    grade: Optional[str] = None
    college: Optional[str] = None
    major: Optional[str] = None


# ============== 课程相关 ==============

class CourseInfo(BaseModel):
    """课程信息（原始）"""
    name: str  # 课程名称
    teacher: Optional[str] = None  # 教师
    location: Optional[str] = None  # 上课地点
    time: int  # 起始节次
    end_time: int = 0  # 结束节次
    week_day: int  # 周几 (1-7)
    weeks: List[int]  # 上课周数


class CourseFetchInput(BaseModel):
    """提取课表输入"""
    user_id: str
    year: str = Field(..., description="学年 e.g. 2024")
    semester: int = Field(..., description="学期 3=第一学期, 12=第二学期")


class CourseFetchResponse(BaseModel):
    """提取课表响应（原始数据供预览）"""
    success: bool
    year: str
    semester: int
    courses: List[CourseInfo]
    message: Optional[str] = None


class CourseCustomInput(BaseModel):
    """自定义课程输入"""
    course_code: str = Field(..., description="课程代码")
    custom_name: Optional[str] = None
    color: str = "#4A90D9"
    location_custom: Optional[str] = None
    note: Optional[str] = None
    class_duration: int = 45
    break_duration: int = 10
    weekday: int = Field(..., ge=1, le=7)
    start_section: int = Field(..., ge=1, le=14)
    end_section: int = Field(..., ge=1, le=14)
    weeks: List[int] = Field(..., description="上课周数列表")


class ManualCourseInput(BaseModel):
    """手动添加课程输入"""
    user_id: str = Field(..., description="用户ID")
    custom_name: str = Field(..., description="课程名称")
    teacher: Optional[str] = None
    location: Optional[str] = None
    color: str = "#4A90D9"
    weekday: int = Field(..., ge=1, le=7)
    start_section: int = Field(..., ge=1, le=14)
    end_section: int = Field(..., ge=1, le=14)
    weeks: List[int] = Field(..., description="上课周数列表")


class CourseCustomResponse(BaseModel):
    """自定义课程响应"""
    id: int
    course_code: str
    custom_name: Optional[str]
    color: str
    location_custom: Optional[str]
    note: Optional[str]
    class_duration: int
    break_duration: int
    weekday: int
    start_section: int
    end_section: int
    weeks: List[int]
    original_name: Optional[str]
    original_location: Optional[str]
    teacher: Optional[str]


class CourseSyncInput(BaseModel):
    """同步课表到本地"""
    user_id: str
    year: str
    semester: int
    raw_json: str  # 原始JSON
    customizations: List[CourseCustomInput] = Field(default_factory=list)


class CourseSyncResponse(BaseModel):
    """同步响应"""
    success: bool
    message: str
    synced_count: int


class LocalCourse(BaseModel):
    """本地课程（美化后）"""
    id: int
    course_code: str
    custom_name: Optional[str]
    color: str
    location: Optional[str]  # 显示用（优先custom_location）
    note: Optional[str]
    class_duration: int
    break_duration: int
    weekday: int
    start_section: int
    end_section: int
    weeks: List[int]
    original_name: Optional[str]
    teacher: Optional[str]


class LocalCoursesResponse(BaseModel):
    """本地课程列表响应"""
    courses: List[LocalCourse]


# ============== 成绩相关 ==============

class GradeInfo(BaseModel):
    """成绩信息"""
    name: str  # 课程名称
    class_id: str  # 教学班ID
    teacher: Optional[str] = None
    is_degree: bool = False  # 是否学位课
    credits: float  # 学分
    gpa: float  # 绩点
    grade_points: float  # 学分绩点
    fraction: float  # 百分成绩
    grade: str  # 等级成绩


class GradesInput(BaseModel):
    """成绩查询输入"""
    user_id: str
    year: str
    semester: int


class GradesResponse(BaseModel):
    """成绩响应"""
    success: bool
    year: str
    semester: int
    grades: List[GradeInfo]
    message: Optional[str] = None


# ============== 错误响应 ==============

class ErrorResponse(BaseModel):
    """错误响应"""
    error: str
    detail: Optional[str] = None
