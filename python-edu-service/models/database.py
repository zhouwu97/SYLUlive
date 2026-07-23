"""SQLAlchemy 数据库模型"""
from sqlalchemy import Column, Integer, String, Text, Boolean, DateTime, inspect, select, text
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
    """初始化数据库，并升级已有 SQLite 教务库后校验关键列。"""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(_migrate_edu_user_schema)
        await conn.run_sync(_verify_edu_user_schema)
    # 旧版本将密码和 Cookie 明文写入数据库。不能安全迁移这些值，
    # 直接清除并要求用户重新绑定，避免遗留凭据继续暴露。
    async with AsyncSessionLocal() as session:
        result = await session.execute(select(EduUser).where(EduUser.raw_password.is_not(None)))
        for user in result.scalars():
            user.raw_password = None
            user.encrypted_password = None
            user.cookie = None
            user.bound = False
            # 已清除历史明文凭据时，不能保留可自动重登的授权会话状态。
            user.authorized = False
            user.session_state = "revoked"
            user.auto_relogin = False
            user.revoked_at = datetime.now()
        await session.commit()
        deleted = await clear_legacy_course_cache(session)
        if any(deleted.values()):
            print(f"已清理退役课表缓存: {deleted}")


def _migrate_edu_user_schema(conn):
    """为旧 SQLite 数据库补齐会话生命周期字段。

    SQLAlchemy 的 create_all 只创建新表，不会升级旧表。此处只使用 SQLite
    支持的 ADD COLUMN，生产 PostgreSQL 仍应先执行随服务发布的 SQL 迁移。
    """
    inspector = inspect(conn)
    if "edu_users" not in inspector.get_table_names():
        return
    columns = {column["name"] for column in inspector.get_columns("edu_users")}
    additions = {
        "authorized": "BOOLEAN NOT NULL DEFAULT 0",
        "session_state": "VARCHAR(20) NOT NULL DEFAULT 'unbound'",
        "auto_relogin": "BOOLEAN NOT NULL DEFAULT 1",
        "authorized_at": "DATETIME",
        "logged_out_at": "DATETIME",
        "revoked_at": "DATETIME",
        "credential_generation": "INTEGER NOT NULL DEFAULT 0",
    }
    for name, definition in additions.items():
        if name not in columns:
            conn.execute(text(f"ALTER TABLE edu_users ADD COLUMN {name} {definition}"))

    # 仅处理尚未升级的旧 bound 记录；已撤销记录的 bound 必为 false，不能恢复。
    conn.execute(text("""
        UPDATE edu_users
        SET authorized = 1,
            session_state = CASE WHEN cookie IS NULL OR cookie = '' THEN 'expired' ELSE 'active' END,
            auto_relogin = 1,
            authorized_at = COALESCE(authorized_at, updated_at, created_at),
            credential_generation = CASE WHEN credential_generation < 1 THEN 1 ELSE credential_generation END
        WHERE bound = 1 AND authorized = 0 AND session_state = 'unbound'
    """))

    # 旧 SQLite 表可能没有 student_id 唯一约束。先报告冲突而不是静默选择
    # 一个账号保留，避免两个 Go user_id 继续共享同一教务身份。
    duplicates = conn.execute(text("""
        SELECT student_id, COUNT(*) AS duplicate_count
        FROM edu_users
        GROUP BY student_id
        HAVING COUNT(*) > 1
        ORDER BY student_id
        LIMIT 10
    """)).all()
    if duplicates:
        conflicts = ", ".join(
            f"{row.student_id} ({row.duplicate_count})" for row in duplicates
        )
        raise RuntimeError(
            f"教务数据库存在重复学号，无法启动并创建唯一索引: {conflicts}"
        )
    conn.execute(text("""
        CREATE UNIQUE INDEX IF NOT EXISTS ux_edu_users_student_id
        ON edu_users(student_id)
    """))


def _verify_edu_user_schema(conn):
    """启动时检查既有数据库结构，避免请求期间才因缺列失败。"""
    inspector = inspect(conn)
    if "edu_users" not in inspector.get_table_names():
        raise RuntimeError("教务数据库缺少 edu_users 表")
    columns = {column["name"] for column in inspector.get_columns("edu_users")}
    required = {
        "user_id", "student_id", "encrypted_password", "cookie", "bound",
        "authorized", "session_state", "auto_relogin", "authorized_at",
        "logged_out_at", "revoked_at", "credential_generation",
    }
    missing = sorted(required - columns)
    if missing:
        raise RuntimeError(f"教务数据库结构不完整，缺少字段: {', '.join(missing)}")
    unique_indexes = inspector.get_indexes("edu_users")
    unique_constraints = inspector.get_unique_constraints("edu_users")
    student_id_unique = any(
        index.get("unique") and index.get("column_names") == ["student_id"]
        for index in unique_indexes
    ) or any(
        constraint.get("column_names") == ["student_id"]
        for constraint in unique_constraints
    )
    if not student_id_unique:
        raise RuntimeError("教务数据库缺少 edu_users.student_id 唯一约束")


async def get_db():
    """获取数据库会话"""
    async with AsyncSessionLocal() as session:
        yield session


class EduUser(Base):
    """教务用户绑定"""
    __tablename__ = "edu_users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(64), unique=True, nullable=False, index=True)
    # 学号是已验证学生身份在教务服务中的唯一镜像，不能被两个 user_id 复用。
    student_id = Column(String(20), unique=True, nullable=False, index=True)
    name = Column(String(50), nullable=True)  # 姓名
    encrypted_password = Column(Text, nullable=True)  # AES-GCM 密文
    raw_password = Column(Text, nullable=True)  # 仅用于识别并清理历史明文列
    cookie = Column(Text, nullable=True)  # AES-GCM 密文
    grade = Column(String(20), nullable=True)
    college = Column(String(100), nullable=True)
    major = Column(String(100), nullable=True)
    # bound 仅供旧调用方兼容，语义与 authorized 保持一致。
    bound = Column(Boolean, default=False)
    authorized = Column(Boolean, default=False, nullable=False)
    session_state = Column(String(20), default="unbound", nullable=False)
    auto_relogin = Column(Boolean, default=True, nullable=False)
    authorized_at = Column(DateTime, nullable=True)
    logged_out_at = Column(DateTime, nullable=True)
    revoked_at = Column(DateTime, nullable=True)
    # 每次 Go 显式绑定递增，旧代次的撤销任务不得影响新凭据。
    credential_generation = Column(Integer, default=0, nullable=False)
    created_at = Column(DateTime, default=datetime.now)
    updated_at = Column(DateTime, default=datetime.now, onupdate=datetime.now)
