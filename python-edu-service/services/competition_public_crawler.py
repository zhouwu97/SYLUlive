"""
创新创业学院比赛通知公开网站爬虫 — cxcyxy.sylu.edu.cn/tztg.htm

职责:
  - 解析通知通告列表页（分页、标题、日期、URL）
  - 解析文章详情页（标题、正文、附件、来源部门）
  - 白名单清洗 HTML
  - 生成 content_hash
  - 增量模式与 reconcile 模式

抓取规则:
  - 单线程顺序执行
  - 请求间隔 ≥ 500ms + 随机抖动
  - 网络错误最多重试 3 次，指数退避
  - 动态解析总页数和分页 URL，不写死
  - 404 文章作为 not_found 处理，不导致整个栏目失败
  - 不下载附件文件体

确认的解析规则（Phase 0 fixture 验证）:
  - 文章链接格式: /info/1089/<article_id>.htm
  - 列表行: <li>/<tr> 含 YYYY-MM-DD + <a href="/info/1089/...">
  - 详情正文: .v_news_content
  - 详情附件: a[href*="download.jsp"]
  - 详情标题: 优先用列表页标题，详情页 h2 仅 fallback
  - 分页: 倒序，首页 /tztg.htm，第 k 页 /tztg/<total-k+1>.htm
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import random
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from typing import Any
from urllib.parse import urljoin, urlparse

import httpx
from bs4 import BeautifulSoup

from services.html_sanitizer import sanitize_html

# ── 常量 ─────────────────────────────────────────────────────────

COMPETITION_BASE_URL = "https://cxcyxy.sylu.edu.cn"
COMPETITION_ALLOWED_HOST = "cxcyxy.sylu.edu.cn"
COMPETITION_LIST_URL = f"{COMPETITION_BASE_URL}/tztg.htm"
COMPETITION_CATEGORY_ID = "1089"
COMPETITION_CATEGORY_NAME = "比赛通知"
COMPETITION_SLUG = "competition"

# 文章链接路径前缀，用于区分文章链接和导航/分页链接
ARTICLE_PATH_PREFIX = f"/info/{COMPETITION_CATEGORY_ID}/"

_CONTACT = os.environ.get("JWC_CRAWLER_CONTACT", "contact via repo")
UA = (
    "SYULive-Competition-Crawler/1.0 "
    f"(+{_CONTACT})"
)

REQUEST_GAP_SEC_MIN = 0.5
REQUEST_GAP_SEC_MAX = 0.8
TIMEOUT_SEC = 15.0
MAX_RETRIES = 3

DEFAULT_MAX_PAGES = 3

CST = timezone(timedelta(hours=8))

# ── 数据类 ───────────────────────────────────────────────────────


@dataclass
class ListItem:
    """列表页中解析出的一条文章摘要"""
    title: str
    publish_date: str  # YYYY-MM-DD
    source_url: str     # 绝对 URL
    source_article_id: str


@dataclass
class ArticleDetail:
    """文章详情页解析结果"""
    source_url: str
    title: str
    publish_date: str
    author_department: str
    content_html: str      # 清洗后
    content_text: str
    attachments: list[dict[str, str]]
    has_attachment: bool
    content_hash: str
    fetch_status: int = 200


@dataclass
class CrawlError:
    """结构化抓取错误"""
    stage: str
    url: str
    code: str
    message: str
    retryable: bool


# ── 实用函数 ─────────────────────────────────────────────────────


def _now_cst_rfc3339() -> str:
    """返回当前 CST 时间的 RFC3339 字符串。"""
    return datetime.now(CST).isoformat()


def _validate_competition_url(raw_url: str) -> None:
    """校验 URL 仅允许 https://cxcyxy.sylu.edu.cn 且无凭据。

    Raises ValueError on invalid URL.
    """
    if not raw_url:
        raise ValueError("empty URL")
    u = urlparse(raw_url)
    if u.scheme != "https":
        raise ValueError(f"scheme must be https, got {u.scheme!r}")
    if u.hostname != COMPETITION_ALLOWED_HOST:
        raise ValueError(f"host must be {COMPETITION_ALLOWED_HOST}, got {u.hostname!r}")
    if u.username or u.password:
        raise ValueError("credentials not allowed in URL")


def _resolve(url: str, base: str = COMPETITION_BASE_URL) -> str:
    """将相对 URL 解析为绝对 URL。

    根相对用站点根；页相对以 base 为基准。
    外部绝对 URL 必须通过 _validate_competition_url 检查。
    """
    if url.startswith(("http://", "https://")):
        _validate_competition_url(url)
        return url
    if url.startswith(("mailto:", "tel:")):
        return url
    return urljoin(base, url)


def _is_competition_article_url(url: str) -> bool:
    """判断 URL 是否为比赛通知文章链接（/info/1089/<id>.htm）。"""
    try:
        u = urlparse(url)
    except Exception:
        return False
    if u.hostname != COMPETITION_ALLOWED_HOST:
        return False
    return u.path.startswith(ARTICLE_PATH_PREFIX) and u.path.endswith(".htm")


def _extract_article_id(source_url: str) -> str:
    """从文章 URL 中提取 article_id（URL 末段数字）。"""
    m = re.search(r"/(\d+)\.htm$", source_url)
    return m.group(1) if m else ""


def _compute_content_hash(
    title: str,
    publish_date: str,
    author_department: str,
    content_html: str,
    attachments: list[dict[str, str]],
) -> str:
    """生成 content_hash (SHA-256)。

    输入项: title + publish_date + author_department + 规范化 content_html
    + 排序后的 attachment_names + 排序后的 attachment_urls
    """
    normalized_html = re.sub(r"\s+", " ", content_html.strip())

    att_names = sorted(a.get("name", "") for a in attachments)
    att_urls = sorted(a.get("url", "") for a in attachments)

    parts = [
        title.strip(),
        publish_date.strip(),
        author_department.strip(),
        normalized_html,
        "\n".join(att_names),
        "\n".join(att_urls),
    ]
    combined = "|".join(parts)
    return hashlib.sha256(combined.encode("utf-8")).hexdigest()


def _add_jitter(base_sec: float) -> float:
    """在基准延迟上添加少量随机抖动。"""
    return base_sec + random.uniform(0, 0.3)


# ── HTTP 请求辅助 ────────────────────────────────────────────────


async def _fetch(
    client: httpx.AsyncClient,
    url: str,
    *,
    max_retries: int = MAX_RETRIES,
) -> tuple[int, str]:
    """GET 请求，带指数退避重试。

    请求前强制校验 URL 域名、scheme 和凭据。
    重定向后最终 URL 也做校验。
    """
    _validate_competition_url(url)

    last_exc: Exception | None = None
    for attempt in range(max_retries):
        try:
            resp = await client.get(url)
            final_url = str(resp.url) if resp.url else url
            if final_url != url:
                _validate_competition_url(final_url)
            return resp.status_code, resp.text
        except (httpx.TimeoutException, ValueError) as e:
            last_exc = e
            if isinstance(e, ValueError):
                return -1, f"<FETCH_REJECTED: {e}>"
            if attempt < max_retries - 1:
                wait = 0.5 * (2 ** attempt)
                await asyncio.sleep(wait)
        except Exception as e:
            last_exc = e
            if attempt < max_retries - 1:
                wait = 0.5 * (2 ** attempt)
                await asyncio.sleep(wait)
    return -1, f"<FETCH_ERROR: {type(last_exc).__name__}>"


# ── 列表页解析 ───────────────────────────────────────────────────


def parse_competition_list_page(
    html: str,
    base_url: str,
) -> list[ListItem]:
    """解析通知通告列表页，提取文章摘要列表。

    解析策略（fixture 已确认）:
      1. 扫描所有 <li> 和 <tr> 行
      2. 行内文本含 YYYY-MM-DD 日期
      3. 行内有 <a href> 链接，且链接属于 /info/1089/ 路径
      4. 排除导航栏、搜索框、分页链接
      5. 标题非空，URL 去重
    """
    soup = BeautifulSoup(html, "html.parser")
    items: list[ListItem] = []
    seen_urls: set[str] = set()

    for row in soup.find_all(["li", "tr"]):
        text = row.get_text(" ", strip=True)
        date_match = re.search(r"20\d{2}-\d{2}-\d{2}", text)
        if not date_match:
            continue

        link = row.find("a", href=True)
        if not link:
            continue

        href = link["href"]
        try:
            source_url = _resolve(href, base_url)
        except ValueError:
            # 外域链接跳过，不中断整个列表解析
            continue

        if not _is_competition_article_url(source_url):
            continue

        # 标题：优先 <a> 内的 <em>，否则 <a> 文本
        em = link.find("em")
        title = em.get_text(strip=True) if em else link.get_text(strip=True)
        if not title:
            title = link.get_text(" ", strip=True)
        if not title:
            continue

        if source_url in seen_urls:
            continue
        seen_urls.add(source_url)

        items.append(ListItem(
            title=title,
            publish_date=date_match.group(0),
            source_url=source_url,
            source_article_id=_extract_article_id(source_url),
        ))

    return items


def parse_competition_total_pages(html: str) -> int:
    """从分页导航中解析总页数。

    解析策略:
      1. 尾页链接 URL 格式: /tztg/<n>.htm → n 代表倒序尾页
      2. 取所有分页链接中最大数字
      3. 回退: 只有一页 → 1
    """
    soup = BeautifulSoup(html, "html.parser")

    # 方法 1: 从"尾页"链接获取
    last_link = soup.select_one("span.p_last a")
    if last_link and last_link.get("href"):
        href = last_link["href"]
        m = re.search(r"/(\d+)\.htm$", href)
        if m:
            # 尾页 = 1，总页数需要从 p_no 推断
            pass

    # 方法 2: 取所有 p_no 链接中最大数字
    max_page = 1
    for a in soup.select("span.p_no a"):
        try:
            page_num = int(a.get_text(strip=True))
            if page_num > max_page:
                max_page = page_num
        except ValueError:
            continue

    # 方法 3: 如果没找到任何分页链接，只有一页
    p_no_links = soup.select("span.p_no a")
    if not p_no_links:
        current = soup.select_one("span.p_no_d")
        if current:
            return 1

    return max_page if max_page > 0 else 1


def build_competition_page_url(page: int, total_pages: int) -> str:
    """构建通知通告分页 URL。

    倒序分页规则:
      第 1 页: /tztg.htm
      第 k 页 (k ≥ 2): /tztg/<total - k + 1>.htm

    例: total=31
      第 1 页: /tztg.htm
      第 2 页: /tztg/30.htm
      第 4 页: /tztg/28.htm
      尾页(31): /tztg/1.htm
    """
    if page <= 1:
        return COMPETITION_LIST_URL
    page_offset = total_pages - page + 1
    return f"{COMPETITION_BASE_URL}/tztg/{page_offset}.htm"


# ── 文章详情页解析 ───────────────────────────────────────────────


def parse_competition_detail(
    html: str,
    source_url: str,
    list_title: str = "",
    list_date: str = "",
    fetch_status: int = 200,
) -> ArticleDetail | None:
    """解析文章详情页。404 等非 200 状态返回 None。

    标题优先用列表页传入的 list_title，详情页 h2 仅作 fallback。
    （fixture 确认：详情页正文内有 h1，不能用"第一个 h1/h2"当标题）
    """
    if fetch_status != 200:
        return None

    soup = BeautifulSoup(html, "html.parser")

    # 标题: 优先列表页标题，详情页 h2 仅 fallback
    title = list_title
    if not title:
        title_el = (
            soup.select_one(".main_contit h2")
            or soup.select_one(".article-title")
            or soup.select_one("h1")
            or soup.select_one("h2")
        )
        if title_el:
            title = title_el.get_text(strip=True)

    # 元信息: .main_contit p — "作者:XXX    时间：YYYY-MM-DD    点击数：..."
    publish_date = list_date
    author_department = ""
    meta_el = soup.select_one(".main_contit p")
    if meta_el:
        meta_text = meta_el.get_text(" ", strip=True)
        m_author = re.search(r"作者[:：]\s*(\S+)", meta_text)
        m_date = re.search(r"时间[:：]\s*(\d{4}-\d{2}-\d{2})", meta_text)
        if m_author:
            author_department = m_author.group(1)
        if m_date and not publish_date:
            publish_date = m_date.group(1)

    # 如果元信息没提取到部门，用默认值
    if not author_department:
        author_department = "创新创业学院"

    # 正文: .v_news_content（fixture 已确认稳定）
    content_el = (
        soup.select_one(".v_news_content")
        or soup.select_one(".article-content")
        or soup.select_one(".content")
    )
    content_html = ""
    content_text = ""
    if content_el:
        raw_html = str(content_el)
        content_html = sanitize_html(raw_html, COMPETITION_BASE_URL)
        content_text = content_el.get_text("\n", strip=True)

    # 附件: a[href*="download.jsp"]（fixture 已确认）
    attachments: list[dict[str, str]] = []
    for a in soup.find_all("a", href=re.compile(r"download\.jsp")):
        href = a.get("href", "")
        filename = a.get_text(strip=True)
        abs_url = _resolve(href, COMPETITION_BASE_URL)
        ext = ""
        if "." in filename:
            ext = filename.rsplit(".", 1)[-1].lower().strip()
        attachments.append({
            "name": filename,
            "url": abs_url,
            "extension": ext,
        })

    has_attachment = len(attachments) > 0

    content_hash = _compute_content_hash(
        title, publish_date, author_department, content_html, attachments
    )

    return ArticleDetail(
        source_url=source_url,
        title=title,
        publish_date=publish_date,
        author_department=author_department,
        content_html=content_html,
        content_text=content_text,
        attachments=attachments,
        has_attachment=has_attachment,
        content_hash=content_hash,
        fetch_status=fetch_status,
    )


# ── 栏目抓取 ─────────────────────────────────────────────────────


async def _fetch_details(
    client: httpx.AsyncClient,
    items: list[ListItem],
    known_urls: set[str],
    accumulator: list[ArticleDetail],
    errors: list[CrawlError],
) -> None:
    """逐个抓取文章详情。404 作为 not_found 处理，不阻断其他文章。

    将列表页标题传入详情解析，作为标题优先来源。
    """
    for item in items:
        await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))
        st, html = await _fetch(client, item.source_url)

        if st == 404:
            errors.append(CrawlError(
                stage="detail_fetch",
                url=item.source_url,
                code="http_404",
                message=f"文章不存在 (404): {item.title[:80]}",
                retryable=False,
            ))
            continue

        if st != 200:
            errors.append(CrawlError(
                stage="detail_fetch",
                url=item.source_url,
                code="upstream_error",
                message=f"获取详情失败 HTTP {st}: {item.title[:80]}",
                retryable=True,
            ))
            continue

        try:
            detail = parse_competition_detail(
                html,
                item.source_url,
                list_title=item.title,
                list_date=item.publish_date,
                fetch_status=st,
            )
            if detail:
                accumulator.append(detail)
        except Exception as e:
            errors.append(CrawlError(
                stage="detail_fetch",
                url=item.source_url,
                code="parse_error",
                message=f"解析文章失败: {type(e).__name__}",
                retryable=False,
            ))


async def crawl_competition(
    client: httpx.AsyncClient,
    known_urls: set[str],
    max_pages: int,
    reconcile: bool,
) -> dict[str, Any]:
    """抓取创新创业学院通知通告栏目。

    Args:
        client: httpx 客户端
        known_urls: 已存在的文章 URL 集合
        max_pages: 最大翻页数（reconcile 模式下强制为 1）
        reconcile: 是否为对账模式
    """
    errors: list[CrawlError] = []
    all_items: list[ArticleDetail] = []
    total_pages_fetched = 0
    total_list_items_seen = 0
    stop_reason = "max_pages_reached"
    list_fetch_succeeded = False

    if reconcile:
        effective_max_pages = 1
    else:
        effective_max_pages = max_pages

    try:
        # ── 1. 获取第一页，解析总页数 ──────────────────────
        st, html = await _fetch(client, COMPETITION_LIST_URL)
        if st != 200:
            errors.append(CrawlError(
                stage="list_fetch",
                url=COMPETITION_LIST_URL,
                code="upstream_error",
                message=f"获取栏目列表失败: HTTP {st}",
                retryable=True,
            ))
            return {
                "items": [],
                "errors": [_crawl_error_to_dict(e) for e in errors],
                "stats": {
                    "pages_fetched": 0,
                    "list_items_seen": 0,
                    "article_details_fetched": 0,
                    "stop_reason": stop_reason,
                    "partial_failure": False,
                },
                "list_fetch_succeeded": False,
            }

        list_fetch_succeeded = True
        total_pages = parse_competition_total_pages(html)
        if total_pages <= 0:
            total_pages = 1

        page_items = parse_competition_list_page(html, COMPETITION_LIST_URL)
        total_list_items_seen += len(page_items)
        total_pages_fetched += 1

        if reconcile:
            detail_items = page_items
        else:
            detail_items = [
                x for x in page_items if x.source_url not in known_urls
            ]

        await _fetch_details(
            client, detail_items, known_urls, all_items, errors
        )
        await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))

        # ── 2. 判断停止条件 ──────────────────────────────
        if reconcile:
            stop_reason = "reconcile_first_page"
            return _build_result(
                all_items, errors, total_pages_fetched,
                total_list_items_seen, stop_reason, list_fetch_succeeded,
            )

        if not detail_items:
            stop_reason = "full_page_known"
            return _build_result(
                all_items, errors, total_pages_fetched,
                total_list_items_seen, stop_reason, list_fetch_succeeded,
            )

        # 计算尾部连续已知数量
        trailing_known = 0
        for item in reversed(page_items):
            if item.source_url in known_urls:
                trailing_known += 1
            else:
                break

        if trailing_known >= 8:
            stop_reason = "trailing_known_boundary"
            return _build_result(
                all_items, errors, total_pages_fetched,
                total_list_items_seen, stop_reason, list_fetch_succeeded,
            )

        # ── 3. 后续页面 ──────────────────────────────────
        for page in range(2, effective_max_pages + 1):
            page_url = build_competition_page_url(page, total_pages)
            await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))

            st, html = await _fetch(client, page_url)
            if st != 200:
                errors.append(CrawlError(
                    stage="list_fetch",
                    url=page_url,
                    code="upstream_error",
                    message=f"获取栏目第{page}页失败: HTTP {st}",
                    retryable=True,
                ))
                continue

            page_items = parse_competition_list_page(html, page_url)
            total_list_items_seen += len(page_items)
            total_pages_fetched += 1

            detail_items = [
                x for x in page_items if x.source_url not in known_urls
            ]

            await _fetch_details(
                client, detail_items, known_urls, all_items, errors
            )
            await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))

            if not detail_items:
                stop_reason = "full_page_known"
                break

            trailing_known = 0
            for item in reversed(page_items):
                if item.source_url in known_urls:
                    trailing_known += 1
                else:
                    break

            if trailing_known >= 8:
                stop_reason = "trailing_known_boundary"
                break
        else:
            stop_reason = "max_pages_reached"

    except Exception as e:
        errors.append(CrawlError(
            stage="list_fetch",
            url=COMPETITION_LIST_URL,
            code="internal_error",
            message=f"栏目处理异常: {type(e).__name__}",
            retryable=False,
        ))

    return _build_result(
        all_items, errors, total_pages_fetched,
        total_list_items_seen, stop_reason, list_fetch_succeeded,
    )


def _crawl_error_to_dict(e: CrawlError) -> dict[str, Any]:
    return {
        "stage": e.stage,
        "url": e.url,
        "code": e.code,
        "message": e.message,
        "retryable": e.retryable,
    }


def _build_result(
    all_items: list[ArticleDetail],
    errors: list[CrawlError],
    pages_fetched: int,
    list_items_seen: int,
    stop_reason: str,
    list_fetch_succeeded: bool,
) -> dict[str, Any]:
    """构建抓取结果字典。"""
    response_items = []
    for detail in all_items:
        response_items.append({
            "source": "cxcy",
            "category": COMPETITION_CATEGORY_NAME,
            "category_slug": COMPETITION_SLUG,
            "category_id": COMPETITION_CATEGORY_ID,
            "source_article_id": _extract_article_id(detail.source_url),
            "source_url": detail.source_url,
            "title": detail.title,
            "publish_date": detail.publish_date,
            "author_department": detail.author_department,
            "content_html": detail.content_html,
            "content_text": detail.content_text,
            "attachments": detail.attachments,
            "has_attachment": detail.has_attachment,
            "content_hash": detail.content_hash,
        })

    partial_failure = len(errors) > 0

    return {
        "items": response_items,
        "errors": [_crawl_error_to_dict(e) for e in errors],
        "stats": {
            "pages_fetched": pages_fetched,
            "list_items_seen": list_items_seen,
            "article_details_fetched": len(response_items),
            "stop_reason": stop_reason,
            "partial_failure": partial_failure,
        },
        "list_fetch_succeeded": list_fetch_succeeded,
    }


# ── 主入口 ───────────────────────────────────────────────────────


class CompetitionPublicCrawler:
    """创新创业学院比赛通知爬虫服务。"""

    def __init__(
        self,
        timeout: float = TIMEOUT_SEC,
        user_agent: str = UA,
    ):
        self.timeout = timeout
        self.user_agent = user_agent

    async def crawl(
        self,
        known_source_urls: list[str],
        max_pages: int = DEFAULT_MAX_PAGES,
        reconcile: bool = False,
    ) -> dict[str, Any]:
        """执行抓取。

        Returns:
            符合 CompetitionCrawlResponse 结构的字典
        """
        generated_at = _now_cst_rfc3339()
        known_urls = set(known_source_urls)

        async def _validate_redirect(request: httpx.Request) -> None:
            _validate_competition_url(str(request.url))

        async with httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=True,
            verify=True,
            headers={"User-Agent": self.user_agent},
            event_hooks={"request": [_validate_redirect]},
        ) as client:
            result = await crawl_competition(
                client, known_urls, max_pages, reconcile,
            )

        all_failed = not result.get("list_fetch_succeeded", False)
        success = not all_failed

        return {
            "success": success,
            "generated_at": generated_at,
            "items": result["items"],
            "stats": result["stats"],
            "errors": result["errors"],
        }
