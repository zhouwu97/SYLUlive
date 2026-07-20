"""教务处列表页、文章页和附件链接解析。"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, asdict
from datetime import datetime
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup

from .catalog import BASE_URL, CategoryConfig


ARTICLE_RE = re.compile(r"/info/(\d+)/(\d+)\.htm$", re.I)


@dataclass
class DiscoveredArticle:
    source: str
    category: str
    category_slug: str
    category_id: str
    source_article_id: str
    source_url: str
    title: str
    publish_date: str


def parse_list(html: bytes, config: CategoryConfig, page_url: str) -> tuple[list[DiscoveredArticle], list[str]]:
    soup = BeautifulSoup(html, "html.parser")
    result: list[DiscoveredArticle] = []
    seen: set[str] = set()
    # 列表页使用相对的 info/... 链接，不能只匹配带前导斜杠的形式。
    for anchor in soup.select("a[href]"):
        href = urljoin(page_url, anchor.get("href", "").strip())
        match = ARTICLE_RE.search(urlparse(href).path)
        if not match or href in seen:
            continue
        seen.add(href)
        item = anchor.find_parent("li")
        date_text = item.find("span").get_text(" ", strip=True) if item and item.find("span") else ""
        title = anchor.get_text(" ", strip=True)
        result.append(DiscoveredArticle("jwc", config.name, config.slug, match.group(1), match.group(2), href, title, normalize_date(date_text)))

    # 分页链接由站点生成，第二页通常是 jwtz/139.htm，不能按序号直接拼接。
    page_links = []
    for anchor in soup.select(".p_pages a[href]"):
        target = urljoin(page_url, anchor["href"])
        if target not in page_links and urlparse(target).hostname == "jwc.sylu.edu.cn":
            page_links.append(target)
    return result, page_links


def parse_article(html: bytes, discovered: DiscoveredArticle, page_url: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    title_node = soup.select_one(".main_contit h2") or soup.find("h1") or soup.find("title")
    title = title_node.get_text(" ", strip=True) if title_node else discovered.title
    meta = soup.select_one(".main_contit p")
    meta_text = meta.get_text(" ", strip=True) if meta else ""
    author = ""
    author_match = re.search(r"作者\s*[:：]\s*(.*?)\s+(?:时间|日期)\s*[:：]", meta_text)
    if author_match:
        author = author_match.group(1).strip()
    date_match = re.search(r"(?:时间|日期)\s*[:：]\s*(\d{4}[-年]\d{1,2}[-月]\d{1,2})", meta_text)
    publish_date = normalize_date(date_match.group(1) if date_match else discovered.publish_date)
    content_node = soup.select_one(".v_news_content") or soup.select_one("#vsb_content_1055")
    if content_node:
        for tag in content_node.select("script, style, iframe"):
            tag.decompose()
        content_html = str(content_node)
        # 附件名称进入附件元数据，避免把“办法.pdf”误当作正文知识。
        text_node = BeautifulSoup(content_html, "html.parser")
        for anchor in text_node.select('a[href*="download.jsp"]'):
            anchor.decompose()
        content_text = text_node.get_text("\n", strip=True)
    else:
        content_html, content_text = "", ""

    attachments = []
    for anchor in soup.select("a[href]"):
        href = urljoin(page_url, anchor.get("href", "").strip())
        path = urlparse(href).path.lower()
        if "download.jsp" not in path and not re.search(r"\.(pdf|docx?|xlsx?|xls|txt|zip|rar|jpg|png)$", path):
            continue
        if urlparse(href).hostname != "jwc.sylu.edu.cn":
            continue
        name = anchor.get_text(" ", strip=True) or path.rsplit("/", 1)[-1]
        extension = path.rsplit(".", 1)[-1] if "." in path.rsplit("/", 1)[-1] else ""
        attachments.append({"name": name[:300], "url": href, "extension": extension[:16]})
    normalized = "\n".join((title, publish_date, content_text, *[a["url"] for a in attachments])).encode("utf-8")
    return {
        **asdict(discovered),
        "title": title[:500],
        "publish_date": publish_date,
        "author_department": author[:128],
        "content_html": content_html,
        "content_text": content_text,
        "attachments": attachments,
        "has_attachment": bool(attachments),
        "content_hash": hashlib.sha256(normalized).hexdigest(),
    }


def normalize_date(value: str) -> str:
    match = re.search(r"(\d{4})\D+(\d{1,2})\D+(\d{1,2})", value or "")
    if not match:
        return ""
    try:
        return datetime(int(match.group(1)), int(match.group(2)), int(match.group(3))).date().isoformat()
    except ValueError:
        return ""
