"""Python 教务服务 - FastAPI 主入口"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from config import HOST, PORT
from models.database import init_db
from routers import auth, courses, grades, erke, spider
import os


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

from fastapi import Depends
from services.internal_auth import require_internal_service_key

# 注册路由
app.include_router(auth.router, dependencies=[Depends(require_internal_service_key)])
app.include_router(courses.router, dependencies=[Depends(require_internal_service_key)])
app.include_router(grades.router, dependencies=[Depends(require_internal_service_key)])
app.include_router(erke.router, dependencies=[Depends(require_internal_service_key)])
app.include_router(spider.router, dependencies=[Depends(require_internal_service_key)])


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
