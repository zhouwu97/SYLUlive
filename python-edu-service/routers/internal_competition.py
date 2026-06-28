"""
创新创业学院比赛通知内部接口 — 专供香港 Go 后端通过 HTTPS 调用

端点:
  POST /api/internal/campus/competition/crawl    抓取比赛通知

安全:
  - 所有请求必须携带 Authorization: Bearer <token>
  - 并发锁防止重复抓取（单进程 asyncio.Lock）
  - 不返回 Python traceback
  - 不接受任意 URL 参数
"""

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException

from dependencies.internal_auth import verify_internal_token
from models.competition_schemas import (
    CompetitionCrawlRequest,
    CompetitionCrawlResponse,
)
from services.competition_public_crawler import CompetitionPublicCrawler

logger = logging.getLogger("competition")

router = APIRouter(
    prefix="/api/internal/campus/competition",
    tags=["创新创业学院比赛通知抓取"],
    dependencies=[Depends(verify_internal_token)],
)

# 进程级并发锁 — 当前单 Uvicorn worker 假设有效
_competition_crawl_lock = asyncio.Lock()


@router.post(
    "/crawl",
    response_model=CompetitionCrawlResponse,
    summary="抓取创新创业学院比赛通知",
    description="增量或对账抓取创新创业学院通知通告栏目的比赛通知。",
)
async def competition_crawl(request: CompetitionCrawlRequest):
    """执行比赛通知抓取。

    状态码:
      200: 成功（含 partial_failure=true）
      401: Token 缺失或错误
      409: 已有抓取任务运行中
      422: 参数校验错误
      503: 栏目列表不可访问
    """
    if _competition_crawl_lock.locked():
        raise HTTPException(
            status_code=409,
            detail="Competition crawl is already running",
        )

    async with _competition_crawl_lock:
        try:
            crawler = CompetitionPublicCrawler()

            effective_max = 1 if request.reconcile else request.max_pages

            result = await crawler.crawl(
                known_source_urls=request.known_source_urls,
                max_pages=effective_max,
                reconcile=request.reconcile,
            )

            if not result["success"]:
                raise HTTPException(
                    status_code=503,
                    detail="Competition list page unreachable",
                )

            return CompetitionCrawlResponse(**result)

        except HTTPException:
            raise
        except Exception as e:
            logger.exception("Competition crawl unexpected error")
            raise HTTPException(
                status_code=500,
                detail="Internal crawler error",
            )
