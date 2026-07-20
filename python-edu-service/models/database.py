"""SQLAlchemy 数据库模型"""
from sqlalchemy import Column, Integer, String, Text, Boolean, DateTime, select
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from datetime import datetime

from config import DATABASE_URL
from services.course_cache_retirement import clear_legacy_course_cache

Base = declarative_base()

# 创建异步引擎
engine = create_async_engine(DATABASE_URL, echo=False)
AsyncSessionLocal = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def init_db():
    """初始化数据库"""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    # 旧版本将密码和 Cookie 明文写入数据库。不能安全迁移这些值，
    # 直接清除并要求用户重新绑定，避免遗留凭据继续暴露。
    async with AsyncSessionLocal() as session:
        result = await session.execute(select(EduUser).where(EduUser.raw_password.is_not(None)))
        for user in result.scalars():
            user.raw_password = None
            user.encrypted_password = None
            user.cookie = None
            user.bound = False
        await session.commit()
        deleted = await clear_legacy_course_cache(session)
        if any(deleted.values()):
            print(f"已清理退役课表缓存: {deleted}")


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
    encrypted_password = Column(Text, nullable=True)  # AES-GCM 密文
    raw_password = Column(Text, nullable=True)  # 仅用于识别并清理历史明文列
    cookie = Column(Text, nullable=True)  # AES-GCM 密文
    grade = Column(String(20), nullable=True)
    college = Column(String(100), nullable=True)
    major = Column(String(100), nullable=True)
    bound = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.now)
    updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)
