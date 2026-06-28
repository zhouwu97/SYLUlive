"""
HTML 白名单清洗工具 — production version

用于将抓取到的原始 HTML 清洗为可入库的安全 HTML。

规则：
- 仅保留白名单标签
- 仅保留白名单属性
- 移除所有 script / style / iframe / object / embed / form 及事件属性
- 移除危险协议
- 将相对 URL 解析为绝对 URL
"""
from __future__ import annotations

import re
from typing import Optional
from urllib.parse import urljoin, urlparse

from bs4 import BeautifulSoup, NavigableString, Tag


ALLOWED_TAGS: frozenset[str] = frozenset({
    "p", "div", "span", "a",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "ul", "ol", "li",
    "table", "thead", "tbody", "tfoot", "tr", "td", "th",
    "caption", "col", "colgroup",
    "strong", "em", "b", "i", "u", "br", "hr",
    "img", "blockquote", "pre", "code",
    "font", "dl", "dt", "dd", "sub", "sup",
    "figure", "figcaption",
})

_GLOBAL_ALLOWED_ATTRS: frozenset[str] = frozenset({
    "title", "align", "valign", "width", "height",
    "colspan", "rowspan", "color", "face", "size",
})

_TAG_ALLOWED_ATTRS: dict[str, frozenset[str]] = {
    "a": frozenset({"href", "target"}),
    "img": frozenset({"src", "alt"}),
    "table": frozenset({"border", "cellpadding", "cellspacing"}),
    "col": frozenset({"span"}),
    "colgroup": frozenset({"span"}),
    "ol": frozenset({"start", "type"}),
    "blockquote": frozenset({"cite"}),
}

_UNSAFE_SCHEMES: frozenset[str] = frozenset({
    "javascript", "vbscript", "data", "mocha", "livescript",
})


def _is_unsafe_url(url: str) -> bool:
    """判断 URL 是否使用危险协议。"""
    if not url:
        return False
    s = url.strip().lower()
    s = re.sub(r"^[\s\x00-\x20]+", "", s)
    try:
        scheme = urlparse(s, allow_fragments=False).scheme
    except ValueError:
        return True
    if not scheme:
        return False
    return scheme in _UNSAFE_SCHEMES


def resolve_url(url: str, base_url: str) -> str:
    """将相对 URL 解析为绝对 URL。"""
    if url is None:
        return ""
    u = url.strip()
    if not u:
        return ""
    if _is_unsafe_url(u):
        return ""
    if u.startswith("//"):
        base_scheme = urlparse(base_url).scheme or "https"
        return f"{base_scheme}:{u}"
    if u.startswith(("http://", "https://", "mailto:", "tel:")):
        return u
    return urljoin(base_url, u)


def _allowed_attrs_for(tag_name: str) -> frozenset[str]:
    return _GLOBAL_ALLOWED_ATTRS | _TAG_ALLOWED_ATTRS.get(tag_name.lower(), frozenset())


def _sanitize_tag(tag: Tag, base_url: str) -> None:
    for child in list(tag.children):
        if isinstance(child, Tag):
            _sanitize_node(child, base_url)

    name = (tag.name or "").lower()
    allowed = _allowed_attrs_for(name)
    for attr in list(tag.attrs.keys()):
        attr_l = attr.lower()
        if attr_l.startswith("on"):
            del tag.attrs[attr]
            continue
        if attr_l == "style":
            del tag.attrs[attr]
            continue
        if attr_l not in allowed:
            del tag.attrs[attr]
            continue
        if attr_l in ("href", "src"):
            val = tag.attrs[attr]
            if isinstance(val, list):
                val = " ".join(val)
            if _is_unsafe_url(val):
                del tag.attrs[attr]
                continue
            tag.attrs[attr] = resolve_url(val, base_url)


def _sanitize_node(node, base_url: str) -> None:
    if isinstance(node, NavigableString):
        return
    if not isinstance(node, Tag):
        return

    name = (node.name or "").lower()

    if name in {
        "script", "style", "iframe", "object", "embed", "noscript",
        "form", "input", "button", "select", "option", "textarea",
        "meta", "link", "base", "applet", "frame", "frameset",
    }:
        node.decompose()
        return

    if name not in ALLOWED_TAGS:
        node.unwrap()
        return

    _sanitize_tag(node, base_url)


def sanitize_html(html: str, base_url: str = "https://jwc.sylu.edu.cn") -> str:
    """白名单清洗 HTML。"""
    if not html:
        return ""
    soup = BeautifulSoup(html, "html.parser")
    for child in list(soup.children):
        if isinstance(child, Tag):
            _sanitize_node(child, base_url)
    out = str(soup)
    out = out.strip()
    return out
