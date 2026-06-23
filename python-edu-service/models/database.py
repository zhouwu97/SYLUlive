"""SQLAlchemy 数据库模型"""
from sqlalchemy import Column, Integer, String, Text, Boolean, DateTime, ForeignKey
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base, relationship
from datetime import datetime

from config import DATABASE_URL

Base = declarative_base()

# 创建异步引擎
engine = create_async_engine(DATABASE_URL, echo=False)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def init_db():
    """初始化数据库"""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_db():
    """获取数据库会话"""
    async with AsyncSessionLocal() as session:
        yield session


class EduUser(Base):
    """教务用户绑定"""
    __tablename__ = "edu_users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(64), unique=True, nullable=False, index=True)
    student_id = Column(String(20), nullable=False)
    name = Column(String(50), nullable=True)  # 姓名
    encrypted_password = Column(Text, nullable=True)  # AES-128-CBC 加密后的凭据
    cookie = Column(Text, nullable=True)
    grade = Column(String(20), nullable=True)
    college = Column(String(100), nullable=True)
    major = Column(String(100), nullable=True)
    bound = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.now)
    updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)


class CourseRaw(Base):
    """课程原始数据（从教务提取）"""
    __tablename__ = "courses_raw"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(64), nullable=False, index=True)
    year = Column(String(10), nullable=False)
    semester = Column(Integer, nullable=False)  # 3=第一学期, 12=第二学期
    raw_json = Column(Text, nullable=False)  # 原始JSON
    fetched_at = Column(DateTime, default=datetime.now)

    # 关系: 移除 uselist=False 以支持多自定义片段对应单个原始课程
    custom = relationship("CourseCustom", back_populates="raw")


class CourseCustom(Base):
    """用户自定义课程数据"""
    __tablename__ = "courses_custom"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(64), nullable=False, index=True)
    course_code = Column(String(64), nullable=False)  # 用于关联原始数据
    raw_id = Column(Integer, ForeignKey("courses_raw.id"), nullable=True)

    # 自定义信息
    custom_name = Column(String(100), nullable=True)  # 自定义简称
    color = Column(String(10), default="#4A90D9")  # 课程颜色
    location_custom = Column(String(200), nullable=True)  # 自定义地点
    note = Column(String(500), nullable=True)  # 备注

    # 时间设置
    class_duration = Column(Integer, default=45)  # 单课时长（分钟）
    break_duration = Column(Integer, default=10)  # 课间休息（分钟）
    weekday = Column(Integer, nullable=False)  # 周几 (1-7, 1=周一)
    start_section = Column(Integer, nullable=False)  # 开始节次
    end_section = Column(Integer, nullable=False)  # 结束节次
    weeks = Column(Text, nullable=False)  # JSON数组 e.g. "[1,2,3,4,5]"

    # 原始信息（用于显示）
    original_name = Column(String(200), nullable=True)
    original_location = Column(String(200), nullable=True)
    teacher = Column(String(100), nullable=True)

    created_at = Column(DateTime, default=datetime.now)
    updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)

    # 关系
    raw = relationship("CourseRaw", back_populates="custom")
