"""
JWC 内部接口 — 专供香港 Go 后端通过 HTTPS 调用

端点:
  POST /api/internal/jwc/crawl    抓取教务通知/公告

安全:
  - 所有请求必须携带 Authorization: Bearer <token>
  - 并发锁防止重复抓取（单进程 asyncio.Lock）
  - 不返回 Python traceback
  - 不接受任意 URL 参数
"""

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException, Request

from dependencies.internal_auth import verify_internal_token
from models.jwc_schemas import (
    CATEGORY_SLUGS,
    MAX_MAX_PAGES,
    CrawlRequest,
    CrawlResponse,
    CrawlStats,
    CrawlError,
    ArticleItem,
    AttachmentItem,
)
from services.jwc_public_crawler import JWCPublicCrawler

logger = logging.getLogger("jwc")

router = APIRouter(
    prefix="/api/internal/jwc",
    tags=["JWC 教务资讯抓取"],
    dependencies=[Depends(verify_internal_token)],
)

# 进程级并发锁 — 当前单 Uvicorn worker 假设有效
_jwc_crawl_lock = asyncio.Lock()


@router.post(
    "/crawl",
    response_model=CrawlResponse,
    summary="抓取 JWC 教务公开资讯",
    description="增量或对账抓取沈阳理工大学教务处公开通知/公告。",
)
async def jwc_crawl(request: CrawlRequest):
    """执行 JWC 公开网站抓取。

    状态码:
      200: 成功（含 partial_failure=true）
      401: Token 缺失或错误
      409: 已有抓取任务运行中
      422: 参数校验错误
      503: 全部栏目不可访问
    """
    # 并发锁
    if _jwc_crawl_lock.locked():
        raise HTTPException(
            status_code=409,
            detail="JWC crawl is already running",
        )

    async with _jwc_crawl_lock:
        try:
            crawler = JWCPublicCrawler()

            # reconcile 模式强制 max_pages=1
            effective_max = 1 if request.reconcile else request.max_pages

            result = await crawler.crawl(
                categories=request.categories,
                known_source_urls=request.known_source_urls,
                max_pages=effective_max,
                reconcile=request.reconcile,
            )

            # 检查是否全部栏目失败
            if not result["success"]:
                raise HTTPException(
                    status_code=503,
                    detail="All categories failed to fetch",
                )

            return CrawlResponse(**result)

        except HTTPException:
            raise
        except Exception as e:
            logger.exception("JWC crawl unexpected error")
            raise HTTPException(
                status_code=500,
                detail="Internal crawler error",
            )
