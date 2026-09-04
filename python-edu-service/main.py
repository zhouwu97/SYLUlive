"""Python 教务服务 - FastAPI 主入口"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from config import HOST, PORT
from models.database import init_db
<<<<<<< HEAD
from routers import auth, courses, grades, erke, spider, internal_jwc, internal_competition, academic_situation, credit_requirements, context_bundle
import os
=======

# 公开校园资讯路由仍可独立运行；个人教务路由由应用工厂按实例加载。
from routers import internal_jwc, internal_competition

_LEGACY_EDU_PATHS = frozenset(
    {
        "/api/login_edu",
        "/api/register_with_edu",
        "/api/password/edu/reset",
    }
)
_PERSONAL_SNAPSHOT_PATHS = frozenset({"/api/personal-snapshots/erke"})


def school_authority_retired() -> bool:
    """读取创建应用实例时使用的进程开关。"""

    raw = os.getenv("SCHOOL_AUTHORITY_RETIRED", "").strip().lower()
    if not raw:
        # 个人教务能力必须 fail-closed；只有显式 false 才允许兼容/测试模式。
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    if raw in {
        "1",
        "true",
        "yes",
        "on",
    }:
        return True
    raise RuntimeError("SCHOOL_AUTHORITY_RETIRED 必须为 true 或 false")
>>>>>>> origin/jiaowu


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理"""
    # 启动时初始化数据库
    await init_db()
    print("数据库初始化完成")
    yield
    # 关闭时清理资源
    print("服务关闭")


# 创建FastAPI应用
app = FastAPI(
    title="沈理校园 - 教务服务",
    description="Python实现的教务系统爬取服务，提供课表和成绩查询",
    version="1.0.0",
    lifespan=lifespan
)

cors_origins_env = os.getenv("CORS_ALLOW_ORIGINS", "")
if cors_origins_env and cors_origins_env != "*":
    origins = [origin.strip() for origin in cors_origins_env.split(",")]
else:
    # Avoid wildcard with allow_credentials=True
    origins = ["http://localhost:3000", "http://localhost:8080", "http://127.0.0.1:3000"]

# 配置CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 注册路由
app.include_router(auth.router)
app.include_router(courses.router)
app.include_router(grades.router)
app.include_router(academic_situation.router)
app.include_router(credit_requirements.router)
app.include_router(context_bundle.router)
app.include_router(erke.router)
app.include_router(spider.router)
app.include_router(internal_jwc.router)
app.include_router(internal_competition.router)


@app.get("/")
async def root():
    """根路径"""
    return {
        "service": "沈理校园 - 教务服务",
        "version": "1.0.0",
        "status": "running"
    }


@app.get("/health")
async def health_check():
    """健康检查"""
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=HOST,
        port=PORT,
        reload=True
    )
