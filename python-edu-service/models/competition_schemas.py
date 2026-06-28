"""
创新创业学院比赛通知 — Pydantic 请求/响应模型

与 jwc_schemas.py 平行，但只有一个固定栏目（通知通告 / tztg）。
source/category/category_slug/category_id 用 Literal 锁死，
避免爬虫内部误填或外部传入错误来源。
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator
from urllib.parse import urlparse


# ── 常量 ────────────────────────────────────────────────────────

COMPETITION_BASE_URL = "https://cxcyxy.sylu.edu.cn"
COMPETITION_ALLOWED_HOST = "cxcyxy.sylu.edu.cn"
COMPETITION_SLUG = "competition"
COMPETITION_CATEGORY_NAME = "比赛通知"
COMPETITION_CATEGORY_ID = "1089"
COMPETITION_LIST_URL = f"{COMPETITION_BASE_URL}/tztg.htm"

MAX_KNOWN_URLS = 200
MIN_MAX_PAGES = 1
MAX_MAX_PAGES = 3
DEFAULT_MAX_PAGES = 3


# ── 请求模型 ────────────────────────────────────────────────────


class CompetitionCrawlRequest(BaseModel):
    """Go → Python 比赛通知抓取请求。

    与 JWC 的 CrawlRequest 不同：
    - 没有 categories 字段（只有一个固定栏目）
    - known_source_urls 是扁平 list，不是按栏目分组的 dict
    """

    known_source_urls: list[str] = Field(
        default_factory=list,
        max_length=MAX_KNOWN_URLS,
        description="已知文章 URL 列表，合计最多 200 条",
    )
    max_pages: int = Field(
        default=DEFAULT_MAX_PAGES,
        ge=MIN_MAX_PAGES,
        le=MAX_MAX_PAGES,
        description=f"最多翻页数，范围 {MIN_MAX_PAGES}～{MAX_MAX_PAGES}",
    )
    reconcile: bool = Field(
        default=False,
        description="是否为对账模式（强制重抓第一页所有文章详情）",
    )

    @model_validator(mode="after")
    def validate_known_urls(self) -> "CompetitionCrawlRequest":
        for url in self.known_source_urls:
            try:
                u = urlparse(url)
            except Exception:
                raise ValueError(
                    f"known_source_urls contains invalid URL: {url!r}"
                )
            if u.scheme != "https":
                raise ValueError(f"known URL must be https: {url!r}")
            if u.hostname != COMPETITION_ALLOWED_HOST:
                raise ValueError(
                    f"known URL host must be {COMPETITION_ALLOWED_HOST}: {url!r}"
                )
        return self


# ── 响应模型 ────────────────────────────────────────────────────


class AttachmentItem(BaseModel):
    """附件信息"""

    name: str = Field(..., description="文件名")
    url: str = Field(..., description="下载中转 URL（绝对路径）")
    extension: str = Field(default="", description="文件扩展名（不包含点）")


class CompetitionArticleItem(BaseModel):
    """抓取到的单篇比赛通知"""

    source: Literal["cxcy"] = "cxcy"
    category: Literal["比赛通知"] = "比赛通知"
    category_slug: Literal["competition"] = "competition"
    category_id: Literal["1089"] = "1089"
    source_article_id: str = Field(..., description="原始文章 ID")
    source_url: str = Field(..., description="文章完整 URL")
    title: str = Field(..., description="文章标题")
    publish_date: str = Field(..., description="发布日期 YYYY-MM-DD")
    author_department: str = Field(default="", description="作者/发布部门")
    content_html: str = Field(default="", description="清洗后的正文 HTML")
    content_text: str = Field(default="", description="纯文本内容")
    attachments: list[AttachmentItem] = Field(default_factory=list)
    has_attachment: bool = Field(default=False)
    content_hash: str = Field(..., description="内容哈希 (SHA-256)")


class CompetitionCrawlStats(BaseModel):
    """抓取统计"""

    pages_fetched: int = Field(default=0)
    list_items_seen: int = Field(default=0)
    article_details_fetched: int = Field(default=0)
    stop_reason: str = Field(
        default="max_pages_reached",
        description="full_page_known | trailing_known_boundary | max_pages_reached | reconcile_first_page",
    )
    partial_failure: bool = Field(default=False)


class CompetitionCrawlError(BaseModel):
    """结构化错误"""

    stage: str = Field(default="", description="错误阶段: list_fetch / detail_fetch")
    url: str = Field(default="", description="关联 URL")
    code: str = Field(default="", description="错误码")
    message: str = Field(default="", description="人类可读错误消息，不含 traceback")
    retryable: bool = Field(default=False)


class CompetitionCrawlResponse(BaseModel):
    """Python → Go 比赛通知抓取响应"""

    success: bool = Field(default=True)
    generated_at: str = Field(
        default="",
        description="响应生成时间，RFC3339 带时区",
    )
    items: list[CompetitionArticleItem] = Field(default_factory=list)
    stats: CompetitionCrawlStats = Field(default_factory=CompetitionCrawlStats)
    errors: list[CompetitionCrawlError] = Field(default_factory=list)
