#!/usr/bin/env python3
"""
教务处公开网站 — 栏目列表页结构探针

读取首页探针输出的 homepage_summary.json，对"教务通知"和"教务公告"两个栏目：
1. 抓取栏目第一页（更多链接）
2. 解析列表项（标题、日期、文章 URL、article_id）
3. 检测置顶/重复文章标记
4. 找到"下页"链接，抓取第二页
5. 识别分页 URL 规则（该站点采用倒序分页：page1=<slug>.htm, page2=<slug>/<N>.htm）
6. 选取样例文章 URL（一篇普通、一篇疑似带附件）供 inspect_article.py 使用

本探针不登录、不使用 Cookie、不执行 JavaScript。
请求间隔 ≥ 500ms，单线程顺序执行。

Usage:
    cd python-edu-service
    python tools/jwc_public_probe/inspect_category.py
"""
import asyncio
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx
from bs4 import BeautifulSoup

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

# 本轮探测的栏目（按 plan，只接教务通知和教务公告）
TARGET_COLUMNS = ["教务通知", "教务公告"]

# 疑似带附件的标题关键词
ATTACHMENT_KEYWORDS = ["安排", "表", "名册", "名单", "日程", "方案", "通知", "公示", "日程"]

# 置顶/高亮的 CSS 类名候选
STICKY_CLASS_CANDIDATES = ["zd", "top", "ding", "sticky", "置顶", "hot"]


def safe_name(s: str) -> str:
    """栏目名 -> 文件名安全串。"""
    return re.sub(r"[^\u4e00-\u9fa5A-Za-z0-9._-]", "_", s)


def extract_article_id(url: str) -> Optional[str]:
    m = re.search(r"/(\d+)\.htm$", url)
    return m.group(1) if m else None


def resolve(url: str, base: str = BASE_URL) -> str:
    if url.startswith("http"):
        return url
    if url.startswith("/"):
        return base + url
    return base + "/" + url


async def fetch(client: httpx.AsyncClient, url: str) -> Tuple[int, str, Dict[str, str]]:
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


def parse_list_page(html: str, base_url: str, column_name: str, page_url: str) -> Dict[str, Any]:
    """解析栏目列表页：列表项、分页、置顶标记。"""
    soup = BeautifulSoup(html, "html.parser")
    info: Dict[str, Any] = {
        "column": column_name,
        "page_url": page_url,
        "items": [],
        "pagination": {
            "next_page_url": None,
            "next_page_url_absolute": None,
            "last_page_url": None,
            "last_page_url_absolute": None,
            "total_pages_display": None,
            "page_numbers_seen": [],
        },
        "sticky_candidates": [],
        "selectors_observed": {},
    }

    # 列表项：<li id="line_u7_N"><span> YYYY-MM-DD</span><a href="info/CAT/ART.htm"><em>title</em></a></li>
    # 也兼容首页式 <li><a href="info/..."><span>[MM-DD]</span><em>title</em></a></li>
    items: List[Dict[str, Any]] = []
    list_items = soup.find_all("li", id=re.compile(r"^line_u\d+_\d+$"))
    if not list_items:
        # 退而求其次：所有包含 info/ 链接的 <li>
        list_items = [li for li in soup.find_all("li") if li.find("a", href=re.compile(r"info/\d+/\d+\.htm"))]

    info["selectors_observed"]["list_item"] = "li[id^=line_u]" if soup.find("li", id=re.compile(r"^line_u\d+_\d+$")) else "li:has(a[href*=info/])"

    for li in list_items:
        a = li.find("a", href=re.compile(r"info/\d+/\d+\.htm"))
        if not a:
            continue
        href = a["href"]
        abs_url = resolve(href, base_url)
        em = a.find("em")
        title = em.get_text(strip=True) if em else a.get_text(strip=True)
        span = li.find("span")
        date_text = span.get_text(strip=True) if span else ""
        # 检测置顶/高亮 CSS 类
        classes = li.get("class", []) or []
        sticky_hit = [c for c in classes if any(st in c.lower() for st in STICKY_CLASS_CANDIDATES)]
        item = {
            "title": title,
            "url": abs_url,
            "article_id": extract_article_id(abs_url),
            "date": date_text,
            "li_id": li.get("id"),
            "li_classes": classes,
            "sticky": bool(sticky_hit),
        }
        items.append(item)
        if sticky_hit:
            info["sticky_candidates"].append({
                "article_id": item["article_id"],
                "title": title,
                "li_classes": classes,
                "matched": sticky_hit,
            })

    info["items"] = items

    # 分页：找 "下页" / "尾页" 链接
    # 该站点分页 HTML 结构：
    #   <span class="p_next p_fun"><a href="jwtz/139.htm">下页</a></span>
    #   <span class="p_last p_fun"><a href="jwtz/1.htm">尾页</a></span>
    #   <span class="p_no_d">1</span>  (当前页，禁用)
    #   <span class="p_no"><a href="jwtz/139.htm">2</a></span>  (其他页号)
    for a in soup.find_all("a"):
        txt = a.get_text(strip=True)
        href = a.get("href", "")
        if txt == "下页":
            info["pagination"]["next_page_url"] = href
            info["pagination"]["next_page_url_absolute"] = resolve(href, base_url)
        elif txt == "尾页":
            info["pagination"]["last_page_url"] = href
            info["pagination"]["last_page_url_absolute"] = resolve(href, base_url)

    # 解析页号链接（p_no 下的 a，文本是页号）
    page_numbers: List[int] = []
    for span in soup.find_all("span", class_="p_no"):
        a = span.find("a")
        if a:
            t = a.get_text(strip=True)
            if t.isdigit():
                page_numbers.append(int(t))
    # 当前页（p_no_d）
    for span in soup.find_all("span", class_=re.compile(r"p_no_d")):
        t = span.get_text(strip=True)
        if t.isdigit():
            page_numbers.append(int(t))
    page_numbers = sorted(set(page_numbers))
    info["pagination"]["page_numbers_seen"] = page_numbers
    if page_numbers:
        info["pagination"]["total_pages_display"] = max(page_numbers)

    return info


def infer_pagination_pattern(page1_url: str, page2_url: str, total_pages: Optional[int]) -> Dict[str, Any]:
    """根据 page1、page2 URL 推断分页规则。"""
    pattern: Dict[str, Any] = {
        "page1_url": page1_url,
        "page2_url": page2_url,
        "total_pages": total_pages,
        "rule": None,
        "formula": None,
    }
    # page1: https://jwc.sylu.edu.cn/jwtz.htm
    # page2: https://jwc.sylu.edu.cn/jwtz/139.htm
    # 倒序：page1 = <slug>.htm, page_k = <slug>/<total-k+1>.htm for k>=2
    m1 = re.match(r"^(https?://[^/]+/)([^/]+)\.htm$", page1_url)
    m2 = re.match(r"^(https?://[^/]+/)([^/]+)/(\d+)\.htm$", page2_url)
    if m1 and m2:
        slug1 = m1.group(2)
        slug2 = m2.group(2)
        n2 = int(m2.group(3))
        if slug1 == slug2 and total_pages:
            # 倒序分页：page_k -> <slug>/<total-k+1>.htm
            pattern["rule"] = "inverted"
            pattern["formula"] = (
                f"page_k (k>=2) = {m2.group(1)}{slug2}/<total-k+1>.htm ; "
                f"page_1 = {m1.group(1)}{slug1}.htm"
            )
            pattern["verified"] = (total_pages - 2 + 1) == n2
        elif slug1 == slug2:
            pattern["rule"] = "inverted_inferred"
            pattern["formula"] = (
                f"page_k (k>=2) = {m2.group(1)}{slug2}/<N>.htm where N decreases; "
                f"page_1 = {m1.group(1)}{slug1}.htm"
            )
    else:
        pattern["rule"] = "unknown"
        pattern["formula"] = "无法从两页 URL 推断通用规则"
    return pattern


def pick_sample_articles(items: List[Dict[str, Any]], n: int = 2) -> List[Dict[str, Any]]:
    """从列表项中选取样例：一篇普通、一篇疑似带附件。"""
    if not items:
        return []
    regular = None
    attachment_likely = None
    for it in items:
        title = it.get("title", "")
        if not attachment_likely and any(kw in title for kw in ATTACHMENT_KEYWORDS):
            attachment_likely = it
        if not regular and not any(kw in title for kw in ATTACHMENT_KEYWORDS):
            regular = it
        if regular and attachment_likely:
            break
    # 退化：如果没找到普通，用第一篇；没找到附件疑似，用最后一篇
    if not regular:
        regular = items[0]
    if not attachment_likely:
        # 找标题里含"安排"或"表"的，否则取末尾
        for it in items:
            if "安排" in it.get("title", "") or "表" in it.get("title", ""):
                attachment_likely = it
                break
        if not attachment_likely and len(items) > 1:
            attachment_likely = items[-1]
        elif not attachment_likely:
            attachment_likely = items[0]

    out = []
    seen_ids = set()
    for kind, it in [("regular", regular), ("attachment_likely", attachment_likely)]:
        if it and it.get("article_id") not in seen_ids:
            out.append({
                "kind": kind,
                "column": it.get("column") if "column" in it else None,
                "title": it.get("title"),
                "url": it.get("url"),
                "article_id": it.get("article_id"),
            })
            seen_ids.add(it.get("article_id"))
    return out[:n]


async def probe_column(client: httpx.AsyncClient, column_name: str, more_url: str) -> Dict[str, Any]:
    """探测单个栏目：抓 page1、page2，返回汇总。"""
    print(f"\n  [{column_name}] 更多 URL: {more_url}")

    print(f"  [page 1] 抓取...")
    st1, html1, hdrs1 = await fetch(client, more_url)
    print(f"    HTTP {st1}, 字节 {len(html1)}")
    if st1 != 200:
        return {"column": column_name, "error": f"page1 HTTP {st1}", "more_url": more_url}

    info1 = parse_list_page(html1, BASE_URL, column_name, more_url)
    info1["fetch_status"] = st1
    n1 = len(info1["items"])
    sticky_n = len(info1["sticky_candidates"])
    print(f"    列表项 {n1} 条, 置顶候选 {sticky_n} 个")
    print(f"    分页: 下页={info1['pagination']['next_page_url_absolute']}, 尾页={info1['pagination']['last_page_url_absolute']}, 总页={info1['pagination']['total_pages_display']}")

    # 保存 page1 脱敏 HTML
    sanitized1 = sanitize_html(html1, BASE_URL)
    safe = safe_name(column_name)
    p1_html_path = OUTPUT / f"category_{safe}_page_1_sanitized.html"
    p1_html_path.write_text(sanitized1, encoding="utf-8")

    # 保存 page1 JSON
    p1_json_path = OUTPUT / f"category_{safe}_page_1_summary.json"
    p1_json_path.write_text(json.dumps(info1, ensure_ascii=False, indent=2), encoding="utf-8")

    total_pages = info1["pagination"]["total_pages_display"]
    next_url = info1["pagination"]["next_page_url_absolute"]

    # 抓 page 2
    info2 = None
    if next_url:
        print(f"  [page 2] 等待 {REQUEST_GAP_SEC}s 后抓取 {next_url}...")
        await asyncio.sleep(REQUEST_GAP_SEC)
        st2, html2, hdrs2 = await fetch(client, next_url)
        print(f"    HTTP {st2}, 字节 {len(html2)}")
        if st2 == 200:
            info2 = parse_list_page(html2, BASE_URL, column_name, next_url)
            info2["fetch_status"] = st2
            n2 = len(info2["items"])
            print(f"    列表项 {n2} 条")
            sanitized2 = sanitize_html(html2, BASE_URL)
            p2_html_path = OUTPUT / f"category_{safe}_page_2_sanitized.html"
            p2_html_path.write_text(sanitized2, encoding="utf-8")
            p2_json_path = OUTPUT / f"category_{safe}_page_2_summary.json"
            p2_json_path.write_text(json.dumps(info2, ensure_ascii=False, indent=2), encoding="utf-8")

    # 推断分页规则
    pattern = infer_pagination_pattern(more_url, next_url or "", total_pages)
    print(f"    分页规则: {pattern['rule']} — {pattern['formula']}")

    # 选取样例文章
    items_all = info1["items"]
    if info2:
        # 只从 page1 选，避免跨页混淆
        pass
    samples = pick_sample_articles(info1["items"], n=2)
    for s in samples:
        s["column"] = column_name
    print(f"    样例文章: {len(samples)} 篇")
    for s in samples:
        print(f"      [{s['kind']}] {s['title'][:40]} -> {s['url']}")

    # 检测重复 article_id（page1 内部）
    ids = [it["article_id"] for it in info1["items"] if it.get("article_id")]
    dup_ids = {aid for aid in ids if ids.count(aid) > 1}

    column_summary: Dict[str, Any] = {
        "column": column_name,
        "more_url": more_url,
        "page1": {
            "url": more_url,
            "status": st1,
            "items_count": n1,
            "sticky_count": sticky_n,
            "duplicate_article_ids_in_page1": sorted(dup_ids),
            "selectors": info1["selectors_observed"],
            "pagination": info1["pagination"],
        },
        "page2": None,
        "pagination_pattern": pattern,
        "sample_articles": samples,
    }
    if info2:
        column_summary["page2"] = {
            "url": next_url,
            "status": info2["fetch_status"],
            "items_count": len(info2["items"]),
            "sticky_count": len(info2["sticky_candidates"]),
        }

    # 保存栏目汇总
    col_path = OUTPUT / f"category_{safe}_summary.json"
    col_path.write_text(json.dumps(column_summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"    汇总 → {col_path}")

    return column_summary


async def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)

    # 读取首页探针输出
    homepage_json = OUTPUT / "homepage_summary.json"
    if not homepage_json.exists():
        print(f"未找到首页探针输出: {homepage_json}")
        print("请先运行: python tools/jwc_public_probe/inspect_homepage.py")
        return 1

    homepage = json.loads(homepage_json.read_text(encoding="utf-8"))
    columns_by_name = {c["name"]: c for c in homepage.get("columns", [])}

    print("=" * 60)
    print("  教务处公开网站 — 栏目列表页结构探针")
    print("=" * 60)
    print(f"目标栏目: {TARGET_COLUMNS}")
    print(f"请求间隔: {REQUEST_GAP_SEC}s, 超时: {TIMEOUT_SEC}s, 重试: {MAX_RETRIES}")
    print()

    all_samples: List[Dict[str, Any]] = []
    all_column_summaries: List[Dict[str, Any]] = []

    async with httpx.AsyncClient(
        timeout=httpx.Timeout(TIMEOUT_SEC),
        follow_redirects=True,
        verify=False,
        headers={"User-Agent": UA},
    ) as client:
        for i, col_name in enumerate(TARGET_COLUMNS):
            if i > 0:
                print(f"\n  等待 {REQUEST_GAP_SEC}s 后探测下一个栏目...")
                await asyncio.sleep(REQUEST_GAP_SEC)
            col = columns_by_name.get(col_name)
            if not col or not col.get("more_url_absolute"):
                print(f"\n  [{col_name}] 未在首页找到更多链接，跳过。")
                continue
            col_summary = await probe_column(client, col_name, col["more_url_absolute"])
            all_column_summaries.append(col_summary)
            all_samples.extend(col_summary.get("sample_articles", []))

    # 保存合并的样例文章 URL 供 inspect_article.py 使用
    samples_path = OUTPUT / "sample_article_urls.json"
    samples_path.write_text(
        json.dumps(all_samples, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"\n样例文章 URL 合并 → {samples_path} ({len(all_samples)} 篇)")

    # 保存栏目汇总索引
    index_path = OUTPUT / "category_index.json"
    index_path.write_text(
        json.dumps({
            "target_columns": TARGET_COLUMNS,
            "columns": all_column_summaries,
        }, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"栏目汇总索引 → {index_path}")

    print("\n完成。")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
