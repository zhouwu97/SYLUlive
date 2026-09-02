"""Python 教务服务 - FastAPI 主入口"""
from contextlib import asynccontextmanager
import os

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from config import HOST, PORT
from models.database import init_db

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


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理"""
    # 退役后不再打开个人教务数据库，避免启动过程触发旧凭据清理/读取链路。
    if not app.state.school_authority_retired:
        await init_db()
        print("数据库初始化完成")
    else:
        print("学校个人教务能力已退役，跳过个人教务数据库初始化")
    yield
    # 关闭时清理资源
    print("服务关闭")


async def root():
    """根路径"""
    return {
        "service": "沈理校园 - 教务服务",
        "version": "1.0.0",
        "status": "running"
    }


async def health_check():
    """健康检查"""
    return {"status": "healthy"}


def _retired_route_code(path: str) -> str | None:
    normalized = path.rstrip("/") or "/"
    if normalized in _LEGACY_EDU_PATHS:
        return "LEGACY_EDU_ROUTE_RETIRED"
    if normalized in _PERSONAL_SNAPSHOT_PATHS:
        return "SCHOOL_ACADEMIC_ROUTE_RETIRED"
    if normalized == "/api/edu" or normalized.startswith("/api/edu/"):
        return "SCHOOL_ACADEMIC_ROUTE_RETIRED"
    return None


def create_app(*, retired: bool | None = None) -> FastAPI:
    """创建配置状态固定的服务实例，避免环境变量与已注册路由不一致。"""

    authority_retired = school_authority_retired() if retired is None else retired
    application = FastAPI(
        title="沈理校园 - 教务服务",
        description="Python实现的教务系统爬取服务，提供课表和成绩查询",
        version="1.0.0",
        lifespan=lifespan,
    )
    application.state.school_authority_retired = authority_retired

    cors_origins_env = os.getenv("CORS_ALLOW_ORIGINS", "")
    if cors_origins_env and cors_origins_env != "*":
        origins = [origin.strip() for origin in cors_origins_env.split(",")]
    else:
        # allow_credentials=True 时不能使用通配来源。
        origins = [
            "http://localhost:3000",
            "http://localhost:8080",
            "http://127.0.0.1:3000",
        ]
    application.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @application.middleware("http")
    async def school_authority_gate(request: Request, call_next):
        """在路由匹配和 Pydantic Body 解析之前切断个人教务入口。"""

        code = _retired_route_code(request.url.path)
        if authority_retired and code is not None:
            message = (
                "旧教务账号入口已退役，请使用邮箱账号"
                if code == "LEGACY_EDU_ROUTE_RETIRED"
                else "服务端学校个人教务能力已退役，请使用设备本地能力"
            )
            return JSONResponse(
                status_code=410,
                content={"code": code, "message": message},
                headers={"Cache-Control": "no-store", "Sunset": "true"},
            )
        return await call_next(request)

    if not authority_retired:
        # 延迟导入避免退役进程加载个人教务 Crawler、模型和凭据生命周期代码。
        from routers import (
            academic_situation,
            auth,
            context_bundle,
            courses,
            credit_requirements,
            erke,
            grades,
            spider,
        )

        application.include_router(auth.router)
        application.include_router(courses.router)
        application.include_router(grades.router)
        application.include_router(academic_situation.router)
        application.include_router(credit_requirements.router)
        application.include_router(context_bundle.router)
        application.include_router(erke.router)
        application.include_router(spider.router)
    application.include_router(internal_jwc.router)
    application.include_router(internal_competition.router)
    application.add_api_route("/", root, methods=["GET"])
    application.add_api_route("/health", health_check, methods=["GET"])
    return application


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=HOST,
        port=PORT,
        reload=True
    )
