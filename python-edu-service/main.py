"""Python 教务服务 - FastAPI 主入口"""
from __future__ import annotations

from contextlib import asynccontextmanager
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.responses import JSONResponse

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
    # 启动时初始化数据库
    await init_db()
    print("数据库初始化完成")
    yield
    # 关闭时清理资源
    print("服务关闭")


def _personal_routers():
    """仅在兼容模式按需导入个人教务路由，退役模式不加载凭据代码。"""

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

    return (
        auth.router,
        courses.router,
        grades.router,
        academic_situation.router,
        credit_requirements.router,
        context_bundle.router,
        erke.router,
        spider.router,
    )


def _retired_response(code: str) -> JSONResponse:
    return JSONResponse(
        status_code=410,
        content={"code": code, "error": "该能力已退役"},
        headers={"cache-control": "no-store", "sunset": "true"},
    )


def _register_retired_routes(app: FastAPI) -> None:
    """为已退役入口提供不读取 Body 的稳定 410 响应。"""

    methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]
    for path in (*_LEGACY_EDU_PATHS, *(f"{path}/" for path in _LEGACY_EDU_PATHS)):
        app.add_api_route(
            path,
            lambda: _retired_response("LEGACY_EDU_ROUTE_RETIRED"),
            methods=methods,
            include_in_schema=False,
        )
    for path in _PERSONAL_SNAPSHOT_PATHS:
        app.add_api_route(
            path,
            lambda: _retired_response("SCHOOL_ACADEMIC_ROUTE_RETIRED"),
            methods=methods,
            include_in_schema=False,
        )
        app.add_api_route(
            f"{path}/{{path:path}}",
            lambda: _retired_response("SCHOOL_ACADEMIC_ROUTE_RETIRED"),
            methods=methods,
            include_in_schema=False,
        )
    app.add_api_route(
        "/api/edu",
        lambda: _retired_response("SCHOOL_ACADEMIC_ROUTE_RETIRED"),
        methods=methods,
        include_in_schema=False,
    )
    app.add_api_route(
        "/api/edu/{path:path}",
        lambda: _retired_response("SCHOOL_ACADEMIC_ROUTE_RETIRED"),
        methods=methods,
        include_in_schema=False,
    )


def create_app(retired: bool | None = None) -> FastAPI:
    """按创建时的退役状态构造应用，避免导入时环境变量污染测试与部署。"""

    retired = school_authority_retired() if retired is None else retired
    app = FastAPI(
        title="沈理校园 - 教务服务",
        description="Python实现的教务系统爬取服务，提供课表和成绩查询",
        version="1.0.0",
        lifespan=lifespan,
    )
    app.state.school_authority_retired = retired

    cors_origins_env = os.getenv("CORS_ALLOW_ORIGINS", "")
    if cors_origins_env and cors_origins_env != "*":
        origins = [origin.strip() for origin in cors_origins_env.split(",")]
    else:
        # 避免 allow_credentials=True 与通配 Origin 组合。
        origins = [
            "http://localhost:3000",
            "http://localhost:8080",
            "http://127.0.0.1:3000",
        ]

    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    if retired:
        _register_retired_routes(app)
    else:
        for router in _personal_routers():
            app.include_router(router)
    app.include_router(internal_jwc.router)
    app.include_router(internal_competition.router)

    @app.get("/")
    async def root():
        """根路径"""
        return {
            "service": "沈理校园 - 教务服务",
            "version": "1.0.0",
            "status": "running",
        }

    @app.get("/health")
    async def health_check():
        """健康检查"""
        return {"status": "healthy"}

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=HOST,
        port=PORT,
        reload=True
    )
