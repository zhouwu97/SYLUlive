"""
JWC 公开网站爬虫 — 沈阳理工大学教务处教务通知/公告

职责:
  - 解析栏目列表页（分页、标题、日期、URL）
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
  - 一个栏目失败不影响另一个
  - 不下载附件文件体
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
from bs4 import BeautifulSoup, Tag

from services.html_sanitizer import sanitize_html

# ── 常量 ─────────────────────────────────────────────────────────

JWC_BASE_URL = "https://jwc.sylu.edu.cn"
JWC_ALLOWED_HOST = "jwc.sylu.edu.cn"

# UA template; JWC_CRAWLER_CONTACT injected at runtime if set
_CONTACT = os.environ.get("JWC_CRAWLER_CONTACT", "contact via repo")
UA = (
    "SYULive-JWC-Crawler/1.0 "
    f"(+{_CONTACT})"
)

REQUEST_GAP_SEC_MIN = 0.5
REQUEST_GAP_SEC_MAX = 0.8
TIMEOUT_SEC = 15.0
MAX_RETRIES = 3

CATEGORY_CONFIG: dict[str, dict[str, str]] = {
    "jwtz": {
        "name": "教务通知",
        "category_id": "1116",
        "list_url": f"{JWC_BASE_URL}/jwtz.htm",
    },
    "jwgg": {
        "name": "教务公告",
        "category_id": "1119",
        "list_url": f"{JWC_BASE_URL}/jwgg.htm",
    },
}

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
    category: str
    stage: str
    url: str
    code: str
    message: str
    retryable: bool


@dataclass
class CategoryResult:
    """单个栏目的抓取结果"""
    slug: str
    items: list[ArticleDetail]
    errors: list[CrawlError]
    pages_fetched: int
    list_items_seen: int
    stop_reason: str  # full_page_known | trailing_known_boundary | max_pages_reached | reconcile_first_page
    list_fetch_succeeded: bool = False  # 列表页至少有一页成功获取


# ── 实用函数 ─────────────────────────────────────────────────────


def _now_cst_rfc3339() -> str:
    """返回当前 CST 时间的 RFC3339 字符串。"""
    return datetime.now(CST).isoformat()


def _validate_jwc_url(raw_url: str) -> None:
    """校验 URL 仅允许 https://jwc.sylu.edu.cn 且无凭据。

    Raises ValueError on invalid URL.
    """
    if not raw_url:
        raise ValueError("empty URL")
    u = urlparse(raw_url)
    if u.scheme != "https":
        raise ValueError(f"scheme must be https, got {u.scheme!r}")
    if u.hostname != JWC_ALLOWED_HOST:
        raise ValueError(f"host must be {JWC_ALLOWED_HOST}, got {u.hostname!r}")
    if u.username or u.password:
        raise ValueError("credentials not allowed in URL")


def _resolve(url: str, base: str = JWC_BASE_URL) -> str:
    """将相对 URL 解析为绝对 URL。

    根相对用站点根；页相对以 base 为基准。
    外部绝对 URL 必须通过 _validate_jwc_url 检查。
    """
    if url.startswith(("http://", "https://")):
        _validate_jwc_url(url)
        return url
    if url.startswith(("mailto:", "tel:")):
        return url
    return urljoin(base, url)


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
    # 规范化 content_html：去除空白差异
    normalized_html = re.sub(r"\s+", " ", content_html.strip())

    # 排序附件名和 URL
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
    _validate_jwc_url(url)

    last_exc: Exception | None = None
    for attempt in range(max_retries):
        try:
            resp = await client.get(url)
            # 重定向后校验最终 URL
            final_url = str(resp.url) if resp.url else url
            if final_url != url:
                _validate_jwc_url(final_url)
            return resp.status_code, resp.text
        except (httpx.TimeoutException, ValueError) as e:
            last_exc = e
            if isinstance(e, ValueError):
                # 域名/协议校验错误不重试
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


def parse_list_page(html: str, base_url: str) -> list[ListItem]:
    """解析栏目列表页，提取文章摘要列表。

    列表项结构:
      <li id="line_u7_0">
        <span> 2026-06-23</span>
        <a href="info/1116/5946.htm"><em>标题</em></a>
      </li>
    """
    soup = BeautifulSoup(html, "html.parser")
    items: list[ListItem] = []

    for li in soup.find_all("li", id=re.compile(r"^line_u")):
        # 日期: li > span
        span = li.find("span")
        date_str = span.get_text(strip=True) if span else ""

        # 标题 & URL: li > a[href] > em
        a_tag = li.find("a", href=True)
        if not a_tag:
            continue

        em = a_tag.find("em")
        title = em.get_text(strip=True) if em else a_tag.get_text(strip=True)

        href = a_tag["href"]
        absolute_url = _resolve(href, base_url)
        article_id = _extract_article_id(absolute_url)

        items.append(ListItem(
            title=title,
            publish_date=date_str,
            source_url=absolute_url,
            source_article_id=article_id,
        ))

    return items


def parse_total_pages(html: str) -> int:
    """从分页导航中解析总页数。

    解析策略:
      1. 尾页链接 URL 格式: <slug>/<1>.htm → 末位数字代表总页数在倒序分页中的尾页
      2. 取所有 p_no 链接中最大数字
      3. 回退: 只有一页 → 1
    """
    soup = BeautifulSoup(html, "html.parser")

    # 方法 1: 从"尾页"链接获取
    last_link = soup.select_one("span.p_last a")
    if last_link and last_link.get("href"):
        href = last_link["href"]
        # 格式: <slug>/<1>.htm — 取最后路径段数字
        m = re.search(r"/(\d+)\.htm$", href)
        if m:
            total_from_last = int(m.group(1))
            # 倒序分页: 尾页 = 1，总页数需要从当前页信息推断
            # 如果只有 link 到 page 1，说明当前在第 1 页且总页数未知
            # 取 p_no 中最大数字更可靠

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
        # 检查是否有禁用当前页标记
        current = soup.select_one("span.p_no_d")
        if current:
            return 1

    return max_page if max_page > 0 else 1


def build_page_url(category_slug: str, page: int, total_pages: int) -> str:
    """构建栏目分页 URL。

    倒序分页规则:
      第 1 页: <BASE>/<slug>.htm
      第 k 页 (k ≥ 2): <BASE>/<slug>/<total - k + 1>.htm
    """
    if page <= 1:
        return f"{JWC_BASE_URL}/{category_slug}.htm"
    page_offset = total_pages - page + 1
    return f"{JWC_BASE_URL}/{category_slug}/{page_offset}.htm"


# ── 文章详情页解析 ───────────────────────────────────────────────


def parse_article_detail(
    html: str,
    source_url: str,
    category_slug: str,
    category_name: str,
    category_id: str,
    fetch_status: int = 200,
) -> ArticleDetail | None:
    """解析文章详情页。404 等非 200 状态返回 None。"""
    if fetch_status != 200:
        return None

    soup = BeautifulSoup(html, "html.parser")

    # 标题: .main_contit h2
    title = ""
    title_el = soup.select_one(".main_contit h2")
    if title_el:
        title = title_el.get_text(strip=True)

    # 元信息: .main_contit p — "作者:XXX    时间：YYYY-MM-DD    点击数：..."
    publish_date = ""
    author_department = ""
    meta_el = soup.select_one(".main_contit p")
    if meta_el:
        meta_text = meta_el.get_text(" ", strip=True)
        m_author = re.search(r"作者[:：]\s*(\S+)", meta_text)
        m_date = re.search(r"时间[:：]\s*(\d{4}-\d{2}-\d{2})", meta_text)
        if m_author:
            author_department = m_author.group(1)
        if m_date:
            publish_date = m_date.group(1)

    # 正文: .v_news_content
    content_el = soup.select_one(".v_news_content") or soup.select_one(
        ".main_conDiv"
    )
    content_html = ""
    content_text = ""
    if content_el:
        raw_html = str(content_el)
        content_html = sanitize_html(raw_html, JWC_BASE_URL)
        content_text = content_el.get_text("\n", strip=True)

    # 附件: a[href*="download.jsp"]
    attachments: list[dict[str, str]] = []
    for a in soup.find_all("a", href=re.compile(r"download\.jsp")):
        href = a.get("href", "")
        filename = a.get_text(strip=True)
        abs_url = _resolve(href, JWC_BASE_URL)
        ext = ""
        if "." in filename:
            ext = filename.rsplit(".", 1)[-1].lower().strip()
        attachments.append({
            "name": filename,
            "url": abs_url,
            "extension": ext,
        })

    has_attachment = len(attachments) > 0

    # content_hash
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


async def crawl_category(
    client: httpx.AsyncClient,
    category_slug: str,
    known_urls: set[str],
    max_pages: int,
    reconcile: bool,
) -> CategoryResult:
    """抓取单个栏目的文章。

    Args:
        client: httpx 客户端
        category_slug: 栏目 slug (jwtz / jwgg)
        known_urls: 已存在的文章 URL 集合
        max_pages: 最大翻页数（reconcile 模式下强制为 1）
        reconcile: 是否为对账模式
    """
    cfg = CATEGORY_CONFIG[category_slug]
    category_id = cfg["category_id"]
    category_name = cfg["name"]
    first_page_url = cfg["list_url"]

    errors: list[CrawlError] = []
    all_items: list[ArticleDetail] = []
    total_pages_fetched = 0
    total_list_items_seen = 0
    stop_reason = "max_pages_reached"

    if reconcile:
        effective_max_pages = 1
    else:
        effective_max_pages = max_pages

    try:
        # ── 1. 获取第一页，解析总页数 ──────────────────────
        st, html = await _fetch(client, first_page_url)
        if st != 200:
            errors.append(CrawlError(
                category=category_slug,
                stage="list_fetch",
                url=first_page_url,
                code="upstream_error",
                message=f"获取栏目列表失败: HTTP {st}",
                retryable=True,
            ))
            return CategoryResult(
                slug=category_slug,
                items=all_items,
                errors=errors,
                pages_fetched=total_pages_fetched,
                list_items_seen=total_list_items_seen,
                stop_reason=stop_reason,
                list_fetch_succeeded=False,
            )

        list_fetch_succeeded = True  # 第一页成功
        total_pages = parse_total_pages(html)
        if total_pages <= 0:
            total_pages = 1

        # 解析第一页列表项
        page_items = parse_list_page(html, first_page_url)
        total_list_items_seen += len(page_items)
        total_pages_fetched += 1

        # 确定要抓的文章
        if reconcile:
            detail_items = page_items  # reconcile: 全抓
        else:
            detail_items = [x for x in page_items if x.source_url not in known_urls]

        await _fetch_details(client, detail_items, category_slug, category_id,
                            category_name, all_items, errors)
        await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))

        # ── 2. 判断停止条件 ──────────────────────────────
        if reconcile:
            stop_reason = "reconcile_first_page"
            return CategoryResult(
                slug=category_slug,
                items=all_items,
                errors=errors,
                pages_fetched=total_pages_fetched,
                list_items_seen=total_list_items_seen,
                stop_reason=stop_reason,
                list_fetch_succeeded=list_fetch_succeeded,
            )

        # 增量模式停止判断
        if not detail_items:
            # 整页全已知
            stop_reason = "full_page_known"
            return CategoryResult(
                slug=category_slug,
                items=all_items,
                errors=errors,
                pages_fetched=total_pages_fetched,
                list_items_seen=total_list_items_seen,
                stop_reason=stop_reason,
                list_fetch_succeeded=list_fetch_succeeded,
            )

        # 计算尾部连续已知数量（倒序遍历）
        trailing_known = 0
        for item in reversed(page_items):
            if item.source_url in known_urls:
                trailing_known += 1
            else:
                break

        if trailing_known >= 8:
            stop_reason = "trailing_known_boundary"
            return CategoryResult(
                slug=category_slug,
                items=all_items,
                errors=errors,
                pages_fetched=total_pages_fetched,
                list_items_seen=total_list_items_seen,
                stop_reason=stop_reason,
                list_fetch_succeeded=list_fetch_succeeded,
            )

        # ── 3. 后续页面 ──────────────────────────────────
        for page in range(2, effective_max_pages + 1):
            page_url = build_page_url(category_slug, page, total_pages)
            await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))

            st, html = await _fetch(client, page_url)
            if st != 200:
                errors.append(CrawlError(
                    category=category_slug,
                    stage="list_fetch",
                    url=page_url,
                    code="upstream_error",
                    message=f"获取栏目第{page}页失败: HTTP {st}",
                    retryable=True,
                ))
                # 一页失败不阻断后续
                continue

            page_items = parse_list_page(html, page_url)
            total_list_items_seen += len(page_items)
            total_pages_fetched += 1

            detail_items = [x for x in page_items if x.source_url not in known_urls]

            await _fetch_details(client, detail_items, category_slug, category_id,
                                category_name, all_items, errors)
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
            category=category_slug,
            stage="list_fetch",
            url=first_page_url,
            code="internal_error",
            message=f"栏目处理异常: {type(e).__name__}",
            retryable=False,
        ))

    return CategoryResult(
        slug=category_slug,
        items=all_items,
        errors=errors,
        pages_fetched=total_pages_fetched,
        list_items_seen=total_list_items_seen,
        stop_reason=stop_reason,
        list_fetch_succeeded=list_fetch_succeeded,
    )


async def _fetch_details(
    client: httpx.AsyncClient,
    items: list[ListItem],
    category_slug: str,
    category_id: str,
    category_name: str,
    accumulator: list[ArticleDetail],
    errors: list[CrawlError],
) -> None:
    """逐个抓取文章详情。404 作为 not_found 处理，不阻断其他文章。"""
    for item in items:
        await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))
        st, html = await _fetch(client, item.source_url)

        if st == 404:
            errors.append(CrawlError(
                category=category_slug,
                stage="detail_fetch",
                url=item.source_url,
                code="http_404",
                message=f"文章不存在 (404): {item.title[:80]}",
                retryable=False,
            ))
            continue

        if st != 200:
            errors.append(CrawlError(
                category=category_slug,
                stage="detail_fetch",
                url=item.source_url,
                code="upstream_error",
                message=f"获取详情失败 HTTP {st}: {item.title[:80]}",
                retryable=True,
            ))
            continue

        try:
            detail = parse_article_detail(
                html, item.source_url, category_slug,
                category_name, category_id, fetch_status=st,
            )
            if detail:
                accumulator.append(detail)
        except Exception as e:
            errors.append(CrawlError(
                category=category_slug,
                stage="detail_fetch",
                url=item.source_url,
                code="parse_error",
                message=f"解析文章失败: {type(e).__name__}",
                retryable=False,
            ))


# ── 主入口 ───────────────────────────────────────────────────────


class JWCPublicCrawler:
    """JWC 公开网站爬虫服务。"""

    def __init__(
        self,
        timeout: float = TIMEOUT_SEC,
        user_agent: str = UA,
    ):
        self.timeout = timeout
        self.user_agent = user_agent

    async def crawl(
        self,
        categories: list[str],
        known_source_urls: dict[str, list[str]],
        max_pages: int = DEFAULT_MAX_PAGES,
        reconcile: bool = False,
    ) -> dict[str, Any]:
        """执行抓取。

        Returns:
            符合 CrawlResponse 结构的字典
        """
        generated_at = _now_cst_rfc3339()

        # 构建每个栏目的已知 URL 集合
        known_sets: dict[str, set[str]] = {}
        for cat in categories:
            urls = known_source_urls.get(cat, [])
            known_sets[cat] = set(urls)

        # 每个重定向步骤都校验目标 URL（异步钩子）
        async def _validate_redirect(request: httpx.Request) -> None:
            _validate_jwc_url(str(request.url))

        async with httpx.AsyncClient(
            timeout=httpx.Timeout(self.timeout),
            follow_redirects=True,
            verify=True,             # 生产必须验证 TLS 证书
            headers={"User-Agent": self.user_agent},
            event_hooks={"request": [_validate_redirect]},
        ) as client:
            # 并行抓取两个栏目（顺序执行，但有独立错误处理）
            results: list[CategoryResult] = []
            for cat in categories:
                result = await crawl_category(
                    client, cat, known_sets.get(cat, set()),
                    max_pages, reconcile,
                )
                results.append(result)
                # 栏目间加间隔
                await asyncio.sleep(_add_jitter(REQUEST_GAP_SEC_MIN))

        # 汇总结果
        all_items: list[ArticleDetail] = []
        all_errors: list[CrawlError] = []
        total_pages = 0
        total_list_items = 0
        stop_reasons: list[str] = []

        for r in results:
            all_items.extend(r.items)
            all_errors.extend(r.errors)
            total_pages += r.pages_fetched
            total_list_items += r.list_items_seen
            stop_reasons.append(r.stop_reason)

        partial_failure = any(len(r.errors) > 0 for r in results)

        # 所有栏目列表页均无法访问 → all_failed
        all_failed = (
            len(results) > 0
            and not any(r.list_fetch_succeeded for r in results)
        )

        # 构建响应
        response_items = []
        cfg = CATEGORY_CONFIG
        for detail in all_items:
            # 根据 URL 确定 category_id
            cat_id = ""
            for slug, cat_cfg in cfg.items():
                if f"/{cat_cfg['category_id']}/" in detail.source_url:
                    cat_id = cat_cfg["category_id"]
                    break

            response_items.append({
                "source": "jwc",
                "category": _get_category_name(detail.source_url),
                "category_slug": _get_category_slug(detail.source_url),
                "category_id": cat_id,
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

        error_dicts = [
            {
                "category": e.category,
                "stage": e.stage,
                "url": e.url,
                "code": e.code,
                "message": e.message,
                "retryable": e.retryable,
            }
            for e in all_errors
        ]

        return {
            "success": not all_failed,
            "generated_at": generated_at,
            "items": response_items,
            "stats": {
                "categories_requested": len(categories),
                "pages_fetched": total_pages,
                "list_items_seen": total_list_items,
                "article_details_fetched": len(response_items),
                "stop_reason": (
                    stop_reasons[0] if len(stop_reasons) == 1 else "mixed"
                ),
                "partial_failure": partial_failure,
            },
            "errors": error_dicts,
        }


def _get_category_name(source_url: str) -> str:
    try:
        path = urlparse(source_url).path
    except Exception:
        return ""
    for slug, cfg in CATEGORY_CONFIG.items():
        if f"/{cfg['category_id']}/" in path:
            return cfg["name"]
    return ""


def _get_category_slug(source_url: str) -> str:
    try:
        path = urlparse(source_url).path
    except Exception:
        return ""
    for slug, cfg in CATEGORY_CONFIG.items():
        if f"/{cfg['category_id']}/" in path:
            return slug
    return ""
