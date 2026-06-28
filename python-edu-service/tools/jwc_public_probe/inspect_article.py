#!/usr/bin/env python3
"""
教务处公开网站 — 文章详情页结构探针

读取 category 探针输出的 sample_article_urls.json，对每篇样例文章：
1. 抓取文章详情页
2. 提取标题、发布日期、来源/部门、正文 HTML（白名单脱敏）、附件（名称+URL+类型+大小）
3. 检测上一篇/下一篇链接
4. 检测是否需要登录（重定向到登录页、403、登录表单、"请登录"文本）
5. 对每个附件 URL 做 HEAD 探测，记录 status / Content-Type / Content-Length
6. 测试一个故意构造的错误 URL，记录 404 行为

本探针不登录、不使用 Cookie、不执行 JavaScript、不下载大体积附件。
请求间隔 ≥ 500ms，单线程顺序执行。

Usage:
    cd python-edu-service
    python tools/jwc_public_probe/inspect_article.py
"""
import asyncio
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup, Tag

PROBE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROBE_DIR))
from sanitize_html import sanitize_html  # noqa: E402

OUTPUT = PROBE_DIR / "output"
BASE_URL = "https://jwc.sylu.edu.cn"

UA = (
    "SYULive-JWC-PublicProbe/1.0 "
    "(+structure probe; public site, no login; contact via repo)"
)

REQUEST_GAP_SEC = 0.5
TIMEOUT_SEC = 15.0
MAX_RETRIES = 3

# 登录墙标记
LOGIN_MARKERS = ["请登录", "登录后", "用户登录", "login", "权限不足", "未授权", "请先登录"]

# 故意构造的错误 URL（用于 404 行为测试）
BAD_URL = "https://jwc.sylu.edu.cn/info/1116/99999999.htm"


def resolve(url: str, base: str = BASE_URL) -> str:
    """将 URL 解析为绝对 URL。使用 urljoin 正确处理根相对和页相对 URL。

    对于页相对 URL（如 "5945.htm"），必须传入文章页 URL 作为 base，
    否则会错误地解析到站点根目录。
    """
    if url.startswith(("http://", "https://", "mailto:", "tel:")):
        return url
    return urljoin(base, url)


async def fetch(client: httpx.AsyncClient, url: str, method: str = "GET") -> Tuple[int, str, Dict[str, str]]:
    last_exc: Optional[Exception] = None
    for attempt in range(MAX_RETRIES):
        try:
            if method == "HEAD":
                resp = await client.head(url)
            else:
                resp = await client.get(url)
            return resp.status_code, resp.text, dict(resp.headers)
        except Exception as e:
            last_exc = e
            if attempt < MAX_RETRIES - 1:
                wait = 0.5 * (2 ** attempt)
                print(f"    [重试 {attempt+1}/{MAX_RETRIES}] {type(e).__name__}: {e} — 等待 {wait}s")
                await asyncio.sleep(wait)
    print(f"    [失败] {url} — {type(last_exc).__name__}: {last_exc}")
    return -1, f"<FETCH_ERROR {type(last_exc).__name__}: {last_exc}>", {}


def parse_article(html: str, url: str, response_headers: Dict[str, str]) -> Dict[str, Any]:
    """解析文章详情页：标题、日期、来源、正文、附件、前后篇、登录墙。"""
    soup = BeautifulSoup(html, "html.parser")
    info: Dict[str, Any] = {
        "url": url,
        "fetch_status": None,
        "title": None,
        "publish_date": None,
        "author_department": None,
        "content_selector_matched": None,
        "content_html_length": 0,
        "attachments": [],
        "prev_link": None,
        "next_link": None,
        "requires_login": False,
        "login_markers_found": [],
        "selectors_observed": {},
    }

    # 页面 <title> — 通常格式 "文章标题-沈阳理工大学教务处"
    page_title = soup.find("title")
    info["page_title"] = page_title.get_text(strip=True) if page_title else None

    # 文章标题：.main_contit h2
    title_el = soup.select_one(".main_contit h2")
    if title_el:
        info["title"] = title_el.get_text(strip=True)
        info["selectors_observed"]["title"] = ".main_contit h2"

    # 作者+日期：.main_contit p — 文本格式 "作者:XXX    时间：YYYY-MM-DD    点击数：..."
    meta_el = soup.select_one(".main_contit p")
    if meta_el:
        meta_text = meta_el.get_text(" ", strip=True)
        info["selectors_observed"]["meta"] = ".main_contit p"
        info["meta_text_raw"] = meta_text
        # 用正则提取
        m_author = re.search(r"作者[:：]\s*(\S+?)\s+", meta_text)
        m_date = re.search(r"时间[:：]\s*(\d{4}-\d{2}-\d{2})", meta_text)
        if m_author:
            info["author_department"] = m_author.group(1)
        if m_date:
            info["publish_date"] = m_date.group(1)

    # 正文容器：优先 .v_news_content（实测稳定命中）
    content_el = soup.select_one(".v_news_content")
    if content_el:
        info["content_selector_matched"] = ".v_news_content"
    else:
        # 回退候选
        for sel in ["#vsb_content", ".article-content", "#article-content", ".news_content", ".content"]:
            el = soup.select_one(sel)
            if el:
                info["content_selector_matched"] = sel
                content_el = el
                break
    if content_el:
        info["selectors_observed"]["content"] = info["content_selector_matched"]
        # 清洗后的正文 HTML
        content_html_sanitized = sanitize_html(str(content_el), BASE_URL)
        info["content_html_length"] = len(content_html_sanitized)
        info["content_text_length"] = len(content_el.get_text(strip=True))
        info["content_preview"] = content_el.get_text(strip=True)[:200]
    else:
        info["content_selector_matched"] = None
        info["selectors_observed"]["content"] = "未命中任何候选选择器"

    # 附件：所有 href 包含 download.jsp 的 <a>，文本即文件名
    # 结构：<li>附件【<a href="/system/_content/download.jsp?...">filename.ext</a>】已下载...次</li>
    attachments: List[Dict[str, Any]] = []
    for a in soup.find_all("a", href=re.compile(r"download\.jsp")):
        href = a["href"]
        filename = a.get_text(strip=True)
        abs_url = resolve(href, BASE_URL)
        # 从文件名推断类型
        ext = ""
        if "." in filename:
            ext = filename.rsplit(".", 1)[-1].lower().strip()
        attachments.append({
            "name": filename,
            "url": abs_url,
            "extension": ext,
            "size": None,  # 由 HEAD 探测填充
            "content_type": None,  # 由 HEAD 探测填充
            "head_status": None,
        })
    info["attachments"] = attachments
    info["selectors_observed"]["attachment"] = 'a[href*="download.jsp"]' if attachments else None

    # 上一篇/下一篇：.main_art ul li
    # 结构：<li><lable>上一篇：</lable><a href="5946.htm">title</a></li>
    # 注意源 HTML 里是 <lable>（typo），bs4 会当作自定义标签
    main_art = soup.select_one(".main_art")
    if main_art:
        info["selectors_observed"]["prev_next"] = ".main_art ul li"
        for li in main_art.find_all("li"):
            label = li.find("lable") or li.find("label")
            a = li.find("a", href=True)
            label_text = label.get_text(strip=True) if label else ""
            if a:
                entry = {
                    "label": label_text,
                    "title": a.get_text(strip=True),
                    # prev/next 使用页相对 URL（如 "5945.htm"），必须以文章页 URL 为基准解析
                    "url": resolve(a["href"], url),
                }
                if "上" in label_text:
                    info["prev_link"] = entry
                elif "下" in label_text:
                    info["next_link"] = entry

    # 登录墙检测
    login_hits: List[str] = []
    low = html.lower()
    for marker in LOGIN_MARKERS:
        if marker.lower() in low:
            login_hits.append(marker)
    # 检测登录表单
    login_form = soup.find("form", attrs={"action": re.compile(r"login", re.I)})
    if login_form:
        login_hits.append("login_form")
    # 检测重定向到登录页（由调用方根据 headers 判断）
    info["login_markers_found"] = login_hits
    info["requires_login"] = bool(login_hits) or response_headers.get("location", "").lower().find("login") >= 0

    return info


async def probe_attachment_head(client: httpx.AsyncClient, attachment: Dict[str, Any]) -> Dict[str, Any]:
    """对附件 URL 做 HEAD 探测，记录 status / content-type / content-length。不下载文件体。"""
    url = attachment["url"]
    print(f"      HEAD {url}")
    st, _, hdrs = await fetch(client, url, method="HEAD")
    if st == -1:
        # HEAD 可能被服务器拒绝，退而求其次用小 Range GET
        print(f"      HEAD 失败，尝试 Range GET bytes=0-0...")
        try:
            resp = await client.get(url, headers={"Range": "bytes=0-0"})
            st = resp.status_code
            hdrs = dict(resp.headers)
        except Exception as e:
            print(f"      Range GET 也失败: {type(e).__name__}: {e}")
            st = -1
            hdrs = {}
    attachment["head_status"] = st
    attachment["content_type"] = hdrs.get("content-type")
    # content-length 可能是 None（chunked）
    cl = hdrs.get("content-length")
    if cl and cl.isdigit():
        attachment["size"] = int(cl)
    else:
        attachment["size"] = None
    print(f"        status={st}, content-type={attachment['content_type']}, content-length={cl}")
    return attachment


async def probe_one_article(client: httpx.AsyncClient, sample: Dict[str, Any]) -> Dict[str, Any]:
    """探测单篇文章。"""
    url = sample["url"]
    kind = sample.get("kind", "?")
    article_id = sample.get("article_id", "?")
    print(f"\n  [{kind}] article_id={article_id}")
    print(f"  URL: {url}")
    print(f"  标题: {sample.get('title', '-')[:60]}")

    st, html, hdrs = await fetch(client, url)
    print(f"  HTTP {st}, 字节 {len(html)}")
    if st != 200:
        print(f"  抓取失败")
        return {
            "sample": sample,
            "fetch_status": st,
            "error": f"HTTP {st}",
            "headers": {k: hdrs.get(k) for k in ("location", "content-type")},
        }

    info = parse_article(html, url, hdrs)
    info["fetch_status"] = st
    print(f"  标题: {info['title']}")
    print(f"  日期: {info['publish_date']}, 来源: {info['author_department']}")
    print(f"  正文容器: {info['content_selector_matched']}, 正文文本长度: {info.get('content_text_length', 0)}")
    print(f"  附件: {len(info['attachments'])} 个")
    for att in info["attachments"]:
        print(f"    - {att['name']} ({att['extension']}) -> {att['url']}")
    print(f"  上一篇: {info['prev_link']}")
    print(f"  下一篇: {info['next_link']}")
    print(f"  需要登录: {info['requires_login']} (标记: {info['login_markers_found']})")

    # 保存脱敏文章 HTML
    sanitized = sanitize_html(html, BASE_URL)
    html_path = OUTPUT / f"article_{article_id}_sanitized.html"
    html_path.write_text(sanitized, encoding="utf-8")
    print(f"  脱敏 HTML → {html_path} ({len(sanitized)} 字节)")

    # HEAD 探测附件
    if info["attachments"]:
        print(f"  附件 HEAD 探测...")
        for att in info["attachments"]:
            await probe_attachment_head(client, att)
            await asyncio.sleep(REQUEST_GAP_SEC)

    # 保存 JSON
    json_path = OUTPUT / f"article_{article_id}_summary.json"
    json_path.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  结构 JSON → {json_path}")

    return {"sample": sample, "info": info}


async def probe_404(client: httpx.AsyncClient) -> Dict[str, Any]:
    """测试故意构造的错误 URL，记录 404 行为。"""
    print(f"\n  [404 测试] {BAD_URL}")
    st, html, hdrs = await fetch(client, BAD_URL)
    print(f"  HTTP {st}, 字节 {len(html)}")
    title_m = re.search(r"<title>(.*?)</title>", html, re.I | re.S)
    title = title_m.group(1).strip() if title_m else None
    print(f"  title: {title}")
    info = {
        "url": BAD_URL,
        "status": st,
        "bytes": len(html),
        "title": title,
        "content_type": hdrs.get("content-type"),
        "note": "故意构造的不存在文章 ID，用于记录 404 行为",
    }
    # 保存 404 响应（脱敏）
    sanitized = sanitize_html(html, BASE_URL)
    (OUTPUT / "article_404_sanitized.html").write_text(sanitized, encoding="utf-8")
    (OUTPUT / "article_404_summary.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    return info


async def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)

    samples_path = OUTPUT / "sample_article_urls.json"
    if not samples_path.exists():
        print(f"未找到样例文章 URL: {samples_path}")
        print("请先运行: python tools/jwc_public_probe/inspect_category.py")
        return 1

    samples = json.loads(samples_path.read_text(encoding="utf-8"))
    if not samples:
        print("样例文章 URL 为空，退出。")
        return 1

    print("=" * 60)
    print("  教务处公开网站 — 文章详情页结构探针")
    print("=" * 60)
    print(f"样例文章: {len(samples)} 篇")
    print(f"请求间隔: {REQUEST_GAP_SEC}s, 超时: {TIMEOUT_SEC}s, 重试: {MAX_RETRIES}")
    print()

    results: List[Dict[str, Any]] = []
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(TIMEOUT_SEC),
        follow_redirects=True,
        verify=False,
        headers={"User-Agent": UA},
    ) as client:
        for i, sample in enumerate(samples):
            if i > 0:
                print(f"\n  等待 {REQUEST_GAP_SEC}s 后抓取下一篇...")
                await asyncio.sleep(REQUEST_GAP_SEC)
            res = await probe_one_article(client, sample)
            results.append(res)

        # 404 测试
        print(f"\n  等待 {REQUEST_GAP_SEC}s 后做 404 边界测试...")
        await asyncio.sleep(REQUEST_GAP_SEC)
        boundary_404 = await probe_404(client)

    # 汇总
    summary = {
        "samples_probed": len(samples),
        "results": results,
        "boundary_404": boundary_404,
        "all_require_login": all(
            r.get("info", {}).get("requires_login", False) for r in results if "info" in r
        ),
        "any_require_login": any(
            r.get("info", {}).get("requires_login", False) for r in results if "info" in r
        ),
    }
    summary_path = OUTPUT / "article_probe_summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n文章探针汇总 → {summary_path}")
    print(f"  全部需要登录: {summary['all_require_login']}")
    print(f"  任一需要登录: {summary['any_require_login']}")
    print(f"  404 测试: HTTP {boundary_404['status']}, title={boundary_404['title']}")

    print("\n完成。")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
