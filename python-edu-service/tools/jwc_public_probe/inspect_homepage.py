#!/usr/bin/env python3
"""
教务处公开网站 — 首页结构探针

抓取 https://jwc.sylu.edu.cn/ 首页，识别 5 个栏目板块（教务通知、教务公告、
教改专题、教学管理文件、下载中心），提取每个栏目的"更多"链接和首页展示的
样例文章列表，检测页面编码，输出脱敏后的 HTML 与结构化 JSON。

本探针不登录、不使用 Cookie、不执行页面 JavaScript。

Usage:
    cd python-edu-service
    python tools/jwc_public_probe/inspect_homepage.py
"""
import asyncio
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx
from bs4 import BeautifulSoup

# 共享清洗器
PROBE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(PROBE_DIR))
from sanitize_html import sanitize_html  # noqa: E402

OUTPUT = PROBE_DIR / "output"

HOME_URL = "https://jwc.sylu.edu.cn/"
BASE_URL = "https://jwc.sylu.edu.cn"

UA = (
    "SYULive-JWC-PublicProbe/1.0 "
    "(+structure probe; public site, no login; contact via repo)"
)

# 5 个栏目名（与首页 h2 文本一致）
COLUMN_NAMES = ["教务通知", "教务公告", "教改专题", "教学管理文件", "下载中心"]

# 请求间隔（毫秒），≥500ms
REQUEST_GAP_SEC = 0.5
TIMEOUT_SEC = 15.0
MAX_RETRIES = 3


async def fetch(client: httpx.AsyncClient, url: str) -> Tuple[int, str, Dict[str, str]]:
    """带重试的 GET 请求。返回 (status, text, headers)。"""
    last_exc: Optional[Exception] = None
    for attempt in range(MAX_RETRIES):
        try:
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


def detect_encoding(text: str, headers: Dict[str, str]) -> str:
    """检测页面编码：优先 meta charset，其次 Content-Type，默认 utf-8。"""
    m = re.search(r'<meta[^>]*charset=["\']?([\w-]+)', text, re.IGNORECASE)
    if m:
        return m.group(1).lower()
    ct = headers.get("content-type", "")
    m2 = re.search(r"charset=([\w-]+)", ct, re.IGNORECASE)
    if m2:
        return m2.group(1).lower()
    return "utf-8"


def extract_article_id(url: str) -> Optional[str]:
    """从 info/<cat>/<id>.htm 这类 URL 提取文章 ID。"""
    m = re.search(r"/(\d+)\.htm$", url)
    return m.group(1) if m else None


def parse_homepage(html: str, base_url: str) -> Dict[str, Any]:
    """解析首页：识别栏目板块、更多链接、样例文章。"""
    soup = BeautifulSoup(html, "html.parser")
    result: Dict[str, Any] = {
        "base_url": base_url,
        "title": None,
        "columns": [],
    }

    # 页面标题
    t = soup.find("title")
    if t:
        result["title"] = t.get_text(strip=True)

    # 逐个栏目查找
    for col_name in COLUMN_NAMES:
        col_info: Dict[str, Any] = {
            "name": col_name,
            "more_url": None,
            "more_url_absolute": None,
            "sample_articles": [],
        }
        # 找到栏目 h2
        h2 = soup.find("h2", string=re.compile(rf"^\s*{re.escape(col_name)}\s*$"))
        if not h2:
            col_info["note"] = "h2 未找到"
            result["columns"].append(col_info)
            continue

        # h2 的父元素（div.dynamic）内有 <span><a href="xxx.htm"><img></a></span>
        parent = h2.parent
        more_a = None
        if parent:
            more_a = parent.find("a", href=True)
        if more_a:
            href = more_a["href"]
            col_info["more_url"] = href
            # 解析为绝对 URL
            if href.startswith("http"):
                col_info["more_url_absolute"] = href
            elif href.startswith("/"):
                col_info["more_url_absolute"] = base_url + href
            else:
                col_info["more_url_absolute"] = base_url + "/" + href

        # 找到栏目板块的容器（向上查找 vsb-space），然后枚举其中的文章链接
        section = h2
        for _ in range(6):
            if section is None:
                break
            section = section.parent
            if section is None:
                break
            # 找到包含 info/ 链接的容器
            if section.find("a", href=re.compile(r"info/\d+/\d+\.htm")):
                break

        sample: List[Dict[str, Any]] = []
        if section:
            for a in section.find_all("a", href=re.compile(r"info/\d+/\d+\.htm")):
                href = a["href"]
                title = (a.get("title") or a.get_text(strip=True) or "").strip()
                # 首页格式：<a><span>[MM-DD]</span><em>title</em></a>
                span = a.find("span")
                date_span = span.get_text(strip=True) if span else ""
                em = a.find("em")
                title_text = em.get_text(strip=True) if em else title
                # 解析绝对 URL
                if href.startswith("http"):
                    abs_url = href
                elif href.startswith("/"):
                    abs_url = base_url + href
                else:
                    abs_url = base_url + "/" + href
                sample.append({
                    "title": title_text,
                    "url": abs_url,
                    "article_id": extract_article_id(abs_url),
                    "date_on_homepage": date_span,  # 首页是 [MM-DD] 格式
                })
                if len(sample) >= 9:
                    break

        col_info["sample_articles"] = sample
        result["columns"].append(col_info)

    return result


async def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    print("=" * 60)
    print("  沈阳理工大学教务处 — 公开首页结构探针")
    print("=" * 60)
    print(f"目标: {HOME_URL}")
    print(f"User-Agent: {UA}")
    print(f"请求间隔: {REQUEST_GAP_SEC}s, 超时: {TIMEOUT_SEC}s, 重试: {MAX_RETRIES}")
    print()

    async with httpx.AsyncClient(
        timeout=httpx.Timeout(TIMEOUT_SEC),
        follow_redirects=True,
        verify=False,
        headers={"User-Agent": UA},
    ) as client:
        print("[1] 抓取首页...")
        st, html, hdrs = await fetch(client, HOME_URL)
        print(f"    HTTP {st}, 字节 {len(html)}")
        if st != 200:
            print(f"    首页抓取失败，退出。")
            return 1

        encoding = detect_encoding(html, hdrs)
        print(f"    编码: {encoding}")
        print(f"    Content-Type: {hdrs.get('content-type', '-')}")

        print("\n[2] 解析栏目结构...")
        summary = parse_homepage(html, BASE_URL)
        summary["encoding"] = encoding
        summary["content_type"] = hdrs.get("content-type")
        summary["fetch_status"] = st
        summary["html_bytes"] = len(html)

        for col in summary["columns"]:
            more = col.get("more_url_absolute") or "-"
            n = len(col.get("sample_articles", []))
            print(f"    {col['name']:6s}  更多→{more:30s}  样例文章 {n} 条")

        print("\n[3] 保存脱敏 HTML...")
        sanitized = sanitize_html(html, BASE_URL)
        (OUTPUT / "homepage_sanitized.html").write_text(sanitized, encoding="utf-8")
        print(f"    → {OUTPUT / 'homepage_sanitized.html'} ({len(sanitized)} 字节)")

        print("\n[4] 保存结构 JSON...")
        json_path = OUTPUT / "homepage_summary.json"
        json_path.write_text(
            json.dumps(summary, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"    → {json_path}")

        print("\n[5] 落盘文件:")
        for p in sorted(OUTPUT.glob("homepage_*")):
            if p.is_file():
                print(f"    {p.relative_to(PROBE_DIR)}")

    print("\n完成。")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
