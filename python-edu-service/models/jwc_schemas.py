"""
JWC 校园资讯爬虫 — Pydantic 请求/响应模型
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any
from urllib.parse import urlparse

from pydantic import BaseModel, Field, model_validator


# ── 常量 ────────────────────────────────────────────────────────

CATEGORY_SLUGS = frozenset({"jwtz", "jwgg"})
CATEGORY_CONFIG: dict[str, dict[str, str]] = {
    "jwtz": {
        "name": "教务通知",
        "category_id": "1116",
        "list_url": "https://jwc.sylu.edu.cn/jwtz.htm",
    },
    "jwgg": {
        "name": "教务公告",
        "category_id": "1119",
        "list_url": "https://jwc.sylu.edu.cn/jwgg.htm",
    },
}
MAX_KNOWN_URLS = 200
MIN_MAX_PAGES = 1
MAX_MAX_PAGES = 3
DEFAULT_MAX_PAGES = 3
JWC_BASE_URL = "https://jwc.sylu.edu.cn"


# ── 请求模型 ────────────────────────────────────────────────────


class CrawlRequest(BaseModel):
    """Go → Python 抓取请求"""

    categories: list[str] = Field(
        ...,
        min_length=1,
        max_length=2,
        description="栏目列表，只能取 jwtz、jwgg",
    )
    known_source_urls: dict[str, list[str]] = Field(
        default_factory=dict,
        description="按栏目分组的已知文章 URL，合计最多 200 条",
    )
    max_pages: int = Field(
        default=DEFAULT_MAX_PAGES,
        ge=MIN_MAX_PAGES,
        le=MAX_MAX_PAGES,
        description=f"每个栏目最多翻页数，范围 {MIN_MAX_PAGES}～{MAX_MAX_PAGES}",
    )
    reconcile: bool = Field(
        default=False,
        description="是否为对账模式（强制重抓第一页所有文章详情）",
    )

    @model_validator(mode="after")
    def validate_categories(self) -> "CrawlRequest":
        for cat in self.categories:
            if cat not in CATEGORY_SLUGS:
                raise ValueError(
                    f"Invalid category: {cat!r}. Allowed: {sorted(CATEGORY_SLUGS)}"
                )
        return self

    @model_validator(mode="after")
    def validate_known_urls_count(self) -> "CrawlRequest":
        # 字典键只能是 jwtz、jwgg
        for key in self.known_source_urls:
            if key not in CATEGORY_SLUGS:
                raise ValueError(
                    f"known_source_urls key must be jwtz or jwgg, got {key!r}"
                )

        total = sum(len(urls) for urls in self.known_source_urls.values())
        if total > MAX_KNOWN_URLS:
            raise ValueError(
                f"known_source_urls total entries ({total}) exceeds max ({MAX_KNOWN_URLS})"
            )
        # 每个 URL 必须通过 urlparse 严格校验
        for cat, urls in self.known_source_urls.items():
            for url in urls:
                try:
                    u = urlparse(url)
                except Exception:
                    raise ValueError(f"known_source_urls contains invalid URL: {url!r}")
                if u.scheme != "https":
                    raise ValueError(f"known URL must be https: {url!r}")
                if u.hostname != "jwc.sylu.edu.cn":
                    raise ValueError(f"known URL host must be jwc.sylu.edu.cn: {url!r}")
        return self


# ── 响应模型 ────────────────────────────────────────────────────


class AttachmentItem(BaseModel):
    """附件信息"""
    name: str = Field(..., description="文件名")
    url: str = Field(..., description="下载中转 URL（绝对路径）")
    extension: str = Field(default="", description="文件扩展名（不包含点）")


class ArticleItem(BaseModel):
    """抓取到的单篇文章"""
    source: str = Field(default="jwc", description="数据来源，固定为 jwc")
    category: str = Field(..., description="栏目中文名")
    category_slug: str = Field(..., description="栏目 slug")
    category_id: str = Field(..., description="栏目 ID")
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


class CrawlStats(BaseModel):
    """抓取统计"""
    categories_requested: int = Field(default=0)
    pages_fetched: int = Field(default=0)
    list_items_seen: int = Field(default=0)
    article_details_fetched: int = Field(default=0)
    stop_reason: str = Field(
        default="max_pages_reached",
        description="full_page_known | trailing_known_boundary | max_pages_reached | reconcile_first_page",
    )
    partial_failure: bool = Field(default=False)


class CrawlError(BaseModel):
    """结构化错误"""
    category: str = Field(default="", description="栏目 slug")
    stage: str = Field(default="", description="错误阶段: list_fetch / detail_fetch")
    url: str = Field(default="", description="关联 URL")
    code: str = Field(default="", description="错误码: upstream_timeout / http_404 / parse_error 等")
    message: str = Field(default="", description="人类可读错误消息，不含 traceback")
    retryable: bool = Field(default=False)


class CrawlResponse(BaseModel):
    """Python → Go 抓取响应"""
    success: bool = Field(default=True)
    generated_at: str = Field(
        default="",
        description="响应生成时间，RFC3339 带时区",
    )
    items: list[ArticleItem] = Field(default_factory=list)
    stats: CrawlStats = Field(default_factory=CrawlStats)
    errors: list[CrawlError] = Field(default_factory=list)
