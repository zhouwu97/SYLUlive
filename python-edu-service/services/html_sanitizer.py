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


# 仅这些标签表达正文的结构边界。inline 标签（尤其是 Visual SiteBuilder
# 为了设置字体而生成的大量 span）不能被当作换行处理。
_SEMANTIC_BLOCK_TAGS: frozenset[str] = frozenset({
    "p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
    "li", "tr", "blockquote", "pre",
})


def extract_semantic_text(html: str | Tag) -> str:
    """从安全 HTML 中提取适合搜索/AI 的语义纯文本。

    与 ``Tag.get_text("\\n")`` 不同，这里只在块级语义节点之间产生段落边界。
    ``span``、``strong``、``em``、``a`` 等 inline 节点的边界只拼接内容，避免
    学校官网常见的 ``<span>竞</span><span>赛名称</span>`` 被错误拆成两行。

    表格行使用 `` | `` 分隔单元格，既保留可检索性，也避免把单元格内容黏在
    一起；图片的 alt 文本会保留到纯文本中。
    """
    if isinstance(html, Tag):
        roots = [html]
    else:
        if not html:
            return ""
        roots = list(BeautifulSoup(html, "html.parser").contents)

    def render(node: object) -> str:
        if isinstance(node, NavigableString):
            value = str(node).replace("\u00a0", " ")
            if not value:
                return ""
            # HTML 源码中的换行/缩进仍然是 inline 空白，保留为空格后在
            # 最终归一化阶段按相邻字符类型处理，而不是直接制造换行。
            return re.sub(r"[ \t\r\n\f\v]+", " ", value)

        if not isinstance(node, Tag):
            return ""

        name = (node.name or "").lower()
        if name in {
            "script", "style", "iframe", "object", "embed", "noscript",
            "form", "input", "button", "select", "option", "textarea",
        }:
            return ""

        if name == "br":
            return "\n"

        if name == "img":
            alt = re.sub(r"\s+", " ", str(node.get("alt", ""))).strip()
            return f"[图片：{alt}]" if alt else ""

        if name == "tr":
            cells: list[str] = []
            for child in node.children:
                if not isinstance(child, Tag):
                    continue
                child_name = (child.name or "").lower()
                if child_name not in {"td", "th"}:
                    continue
                cell = render_children(child)
                cell = re.sub(r"\s*\n\s*", " ", cell)
                cell = re.sub(r"[ \t]+", " ", cell).strip()
                cells.append(cell)
            return " | ".join(cell for cell in cells if cell) + "\n\n"

        content = render_children(node)
        if name in _SEMANTIC_BLOCK_TAGS:
            return content + "\n\n" if content.strip() else ""
        return content

    def render_children(node: Tag) -> str:
        return "".join(render(child) for child in node.children)

    text = "".join(render(root) for root in roots)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t\f\v]+", " ", text)
    text = re.sub(r"[ ]*\n[ ]*", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    # 中文正文中，编辑器为了排版产生的 inline 空白不应改变词语本身；
    # 英文/数字之间的正常空格仍然保留。
    text = re.sub(
        r"(?<=[\u3400-\u9fff\uf900-\ufaff]) +(?=[\u3400-\u9fff\uf900-\ufaff])",
        "",
        text,
    )
    return text.strip()
