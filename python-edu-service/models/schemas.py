"""Pydantic 数据模型"""
from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime


# ============== ��֤��� ==============

class BindInput(BaseModel):
    """�󶨽����˺�����"""
    student_id: str = Field(..., min_length=10, max_length=10, description="ѧ��")
    password: str = Field(..., description="��������")


class BindResponse(BaseModel):
    """����Ӧ"""
    success: bool
    message: str
    code: Optional[str] = None
    student_id: str
    cookie: Optional[str] = None  # ��¼Cookie����Go�������洢
    name: Optional[str] = None
    grade: Optional[str] = None
    college: Optional[str] = None
    major: Optional[str] = None


class UnbindResponse(BaseModel):
    """�����Ӧ"""
    success: bool
    message: str


class EduStatusResponse(BaseModel):
    """�����״̬"""
    bound: bool
    student_id: Optional[str] = None
    name: Optional[str] = None
    grade: Optional[str] = None
    college: Optional[str] = None
    major: Optional[str] = None


class PreVerifyInput(BaseModel):
    """Ԥ��֤�����˺�����"""
    student_id: str = Field(..., min_length=10, max_length=10, description="ѧ��")
    password: str = Field(..., description="��������")


class PreVerifyResponse(BaseModel):
    """Ԥ��֤��Ӧ"""
    success: bool
    message: str
    code: Optional[str] = None
    student_id: Optional[str] = None
    name: Optional[str] = None


class LoginEduInput(BaseModel):
    """ͳһ��¼����"""
    student_id: str = Field(..., min_length=10, max_length=10, description="ѧ��")
    edu_password: str = Field(..., description="��������")
    password: str = Field(..., min_length=8, max_length=32, description="APP����")


class LoginEduResponse(BaseModel):
    """ͳһ��¼��Ӧ"""
    success: bool
    message: str
    code: Optional[str] = None
    student_id: Optional[str] = None
    name: Optional[str] = None
    grade: Optional[str] = None
    college: Optional[str] = None
    major: Optional[str] = None


# ============== �γ���� ==============

class CourseInfo(BaseModel):
    """�γ���Ϣ��ԭʼ��"""
    name: str  # �γ�����
    teacher: Optional[str] = None  # ��ʦ
    location: Optional[str] = None  # �Ͽεص�
    time: int  # ��ʼ�ڴ�
    end_time: int = 0  # �����ڴ�
    week_day: int  # �ܼ� (1-7)
    weeks: List[int]  # �Ͽ�����


class CourseFetchInput(BaseModel):
    """��ȡ�α�����"""
    user_id: str
    year: str = Field(..., description="ѧ�� e.g. 2024")
    semester: int = Field(..., description="ѧ�� 3=��һѧ��, 12=�ڶ�ѧ��")


class CourseFetchResponse(BaseModel):
    """��ȡ�α���Ӧ��ԭʼ���ݹ�Ԥ����"""
    success: bool
    year: str
    semester: int
    courses: List[CourseInfo]
    message: Optional[str] = None


# ============== �ɼ���� ==============

class GradeInfo(BaseModel):
    """�ɼ���Ϣ"""
    name: str  # �γ�����
    course_id: str = ""  # �γ�ID
    course_code: str = ""  # �γ̱��
    class_id: str  # ��ѧ��ID
    student_grade_id: str = ""  # ѧ���ɼ���������Ľ���ϵͳID
    teacher: Optional[str] = None
    is_degree: bool = False  # �Ƿ�ѧλ��
    credits: float  # ѧ��
    gpa: float  # ����
    grade_points: float  # ѧ�ּ���
    fraction: float  # �ٷֳɼ�
    grade: str  # �ȼ��ɼ�
    exam_type: Optional[str] = None  # �������� / ���� / ����
    course_category: Optional[str] = None  # ���޿γ� / ���޿γ̵�
    assessment_method: Optional[str] = None  # ���� / ����


class GradesInput(BaseModel):
    """�ɼ���ѯ����"""
    user_id: str
    year: str
    semester: int


class GradesResponse(BaseModel):
    """�ɼ���Ӧ"""
    success: bool
    year: str
    semester: int
    grades: List[GradeInfo]
    message: Optional[str] = None


class GradeComponent(BaseModel):
    """�ɼ����ɷ���"""
    name: str
    weight: Optional[str] = None
    score: str


class GradeDetailInput(BaseModel):
    """�ɼ���ϸ��ѯ����"""
    user_id: str
    year: str
    semester: int
    class_id: str
    course_name: str
    course_id: Optional[str] = None
    student_grade_id: Optional[str] = None


class GradeDetailResponse(BaseModel):
    """�ɼ���ϸ��Ӧ"""
    success: bool
    course_name: str
    total_grade: str
    components: List[GradeComponent]
    message: Optional[str] = None


class AcademicSituationInput(BaseModel):
    """ѧҵ�����ѯ����"""
    user_id: str
    force_refresh: bool = False


class AcademicCourseInfo(BaseModel):
    """���������γ�������"""
    study_status: Optional[str] = None
    academic_year: Optional[str] = None
    semester: Optional[str] = None
    course_code: str = ""
    course_name: str = ""
    hours: Optional[str] = None
    course_nature: Optional[str] = None
    credits: float = 0
    course_category: Optional[str] = None
    max_grade: Optional[str] = None
    gpa: Optional[float] = None
    grade: Optional[str] = None
    makeup_grade: Optional[str] = None
    retake_grade: Optional[str] = None
    suggested_year: Optional[str] = None
    suggested_semester: Optional[str] = None
    important_nature_count: Optional[str] = None
    is_degree: bool = False
    has_retake: bool = False
    effective_grade: Optional[str] = None
    effective_passed: Optional[bool] = None


class AcademicSituationResponse(BaseModel):
    """ѧ��ѧҵ�����ѯ��Ӧ"""
    success: bool
    source: str = "academic_situation"
    all_gpa: Optional[float] = None
    degree_gpa: Optional[float] = None

    total_courses: int = 0
    passed_courses: int = 0
    failed_courses: int = 0
    not_started_courses: int = 0
    in_progress_courses: int = 0

    degree_total_courses: int = 0
    degree_passed_courses: int = 0
    degree_failed_courses: int = 0
    degree_not_started_courses: int = 0
    degree_in_progress_courses: int = 0

    courses: List[AcademicCourseInfo] = Field(default_factory=list)
    message: Optional[str] = None
    updated_at: Optional[str] = None


# ============== ������Ӧ ==============

class ErrorResponse(BaseModel):
    """������Ӧ"""
    error: str
    detail: Optional[str] = None
