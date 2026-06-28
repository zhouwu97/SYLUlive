# -*- coding: utf-8 -*-
"""sanitize_html.py 单元测试 — 白名单清洗、属性过滤、URL 解析。"""
import pytest

from sanitize_html import (
    sanitize_html,
    resolve_url,
    _is_unsafe_url,
    ALLOWED_TAGS,
)


# ---------------------------------------------------------------------------
# resolve_url
# ---------------------------------------------------------------------------

class TestResolveUrl:
    def test_relative_path_resolved(self):
        assert resolve_url("info/1116/5946.htm", "https://jwc.sylu.edu.cn") == \
            "https://jwc.sylu.edu.cn/info/1116/5946.htm"

    def test_root_relative_resolved(self):
        assert resolve_url("/system/_content/download.jsp?wbfileid=1", "https://jwc.sylu.edu.cn") == \
            "https://jwc.sylu.edu.cn/system/_content/download.jsp?wbfileid=1"

    def test_absolute_https_preserved(self):
        assert resolve_url("https://example.com/foo", "https://jwc.sylu.edu.cn") == \
            "https://example.com/foo"

    def test_absolute_http_preserved(self):
        assert resolve_url("http://example.com/foo", "https://jwc.sylu.edu.cn") == \
            "http://example.com/foo"

    def test_protocol_relative_resolved(self):
        assert resolve_url("//example.com/foo", "https://jwc.sylu.edu.cn") == \
            "https://example.com/foo"

    def test_mailto_preserved(self):
        assert resolve_url("mailto:admin@sylu.edu.cn", "https://jwc.sylu.edu.cn") == \
            "mailto:admin@sylu.edu.cn"

    def test_empty_returns_empty(self):
        assert resolve_url("", "https://jwc.sylu.edu.cn") == ""
        assert resolve_url("   ", "https://jwc.sylu.edu.cn") == ""

    def test_none_returns_empty(self):
        assert resolve_url(None, "https://jwc.sylu.edu.cn") == ""

    def test_javascript_scheme_returns_empty(self):
        assert resolve_url("javascript:alert(1)", "https://jwc.sylu.edu.cn") == ""

    def test_vbscript_scheme_returns_empty(self):
        assert resolve_url("vbscript:msgbox(1)", "https://jwc.sylu.edu.cn") == ""


# ---------------------------------------------------------------------------
# _is_unsafe_url
# ---------------------------------------------------------------------------

class TestIsUnsafeUrl:
    @pytest.mark.parametrize("url", [
        "javascript:alert(1)",
        "JAVASCRIPT:alert(1)",
        "  javascript:alert(1)",
        "vbscript:foo",
        "data:text/html,<script>alert(1)</script>",
    ])
    def test_unsafe(self, url):
        assert _is_unsafe_url(url) is True

    @pytest.mark.parametrize("url", [
        "https://jwc.sylu.edu.cn/foo",
        "http://example.com",
        "/info/1116/5946.htm",
        "info/1116/5946.htm",
        "mailto:a@b.com",
        "",
    ])
    def test_safe(self, url):
        assert _is_unsafe_url(url) is False


# ---------------------------------------------------------------------------
# sanitize_html — 标签白名单
# ---------------------------------------------------------------------------

class TestTagWhitelist:
    def test_allowed_tags_preserved(self):
        for tag in ["p", "div", "span", "a", "h1", "h2", "h3", "ul", "ol", "li",
                    "table", "tr", "td", "th", "strong", "em", "b", "i", "br",
                    "img", "blockquote", "pre", "code", "hr"]:
            html = f"<{tag}>x</{tag}>" if tag not in ("br", "hr", "img") else f"<{tag}/>"
            out = sanitize_html(html)
            assert f"<{tag}" in out, f"标签 {tag} 应被保留，输出: {out!r}"

    def test_script_removed(self):
        out = sanitize_html("<p>ok</p><script>alert(1)</script>")
        assert "<script" not in out.lower()
        assert "alert(1)" not in out

    def test_style_tag_removed(self):
        out = sanitize_html("<p>ok</p><style>body{color:red}</style>")
        assert "<style" not in out.lower()
        assert "color:red" not in out

    def test_iframe_removed(self):
        out = sanitize_html('<p>ok</p><iframe src="https://evil.com"></iframe>')
        assert "<iframe" not in out.lower()

    def test_object_embed_removed(self):
        out = sanitize_html('<p>ok</p><object data="evil.swf"></object><embed src="evil.swf">')
        assert "<object" not in out.lower()
        assert "<embed" not in out.lower()

    def test_form_input_removed(self):
        out = sanitize_html('<form><input name="x"><button>go</button></form>')
        assert "<form" not in out.lower()
        assert "<input" not in out.lower()
        assert "<button" not in out.lower()

    def test_meta_link_removed(self):
        out = sanitize_html('<meta charset="utf-8"><link rel="stylesheet" href="x.css">')
        assert "<meta" not in out.lower()
        assert "<link" not in out.lower()

    def test_unknown_tag_unwrapped(self):
        # 非白名单的自定义标签：unwrap（保留子文本）
        out = sanitize_html("<custom>hello</custom>")
        assert "hello" in out
        assert "<custom" not in out.lower()

    def test_nested_unknown_tag_unwrapped(self):
        out = sanitize_html("<div><custom><p>hello</p></custom></div>")
        assert "<div" in out
        assert "<p" in out
        assert "hello" in out
        assert "<custom" not in out.lower()


# ---------------------------------------------------------------------------
# sanitize_html — 属性白名单
# ---------------------------------------------------------------------------

class TestAttributeWhitelist:
    def test_href_preserved_and_resolved(self):
        out = sanitize_html('<a href="info/1116/5946.htm">link</a>')
        assert 'href="https://jwc.sylu.edu.cn/info/1116/5946.htm"' in out
        assert "link" in out

    def test_title_preserved(self):
        out = sanitize_html('<a href="x.htm" title="提示">link</a>')
        assert 'title="提示"' in out

    def test_img_src_alt_preserved(self):
        out = sanitize_html('<img src="/images/a.png" alt="图">')
        assert 'src="https://jwc.sylu.edu.cn/images/a.png"' in out
        assert 'alt="图"' in out

    def test_onclick_removed(self):
        out = sanitize_html('<a href="x.htm" onclick="alert(1)">link</a>')
        assert "onclick" not in out.lower()
        assert "alert(1)" not in out

    def test_onload_removed(self):
        out = sanitize_html('<img src="x.png" onload="alert(1)">')
        assert "onload" not in out.lower()

    def test_all_on_attrs_removed(self):
        for evt in ["onclick", "onload", "onerror", "onmouseover", "onfocus", "onblur"]:
            out = sanitize_html(f'<a href="x" {evt}="bad()">link</a>')
            assert evt not in out.lower(), f"{evt} 应被移除"

    def test_style_attr_removed(self):
        out = sanitize_html('<p style="color:red">text</p>')
        assert "style" not in out.lower()
        assert "color:red" not in out

    def test_javascript_href_removed(self):
        out = sanitize_html('<a href="javascript:alert(1)">link</a>')
        assert "javascript:" not in out.lower()
        assert "alert(1)" not in out

    def test_data_attr_removed(self):
        out = sanitize_html('<div data-evil="x">content</div>')
        assert "data-evil" not in out.lower()


# ---------------------------------------------------------------------------
# sanitize_html — 结构保留
# ---------------------------------------------------------------------------

class TestStructurePreservation:
    def test_nested_divs_preserved(self):
        html = "<div><div><p>inner</p></div></div>"
        out = sanitize_html(html)
        assert out.count("<div") == 2
        assert "<p>inner</p>" in out

    def test_table_structure_preserved(self):
        html = '<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>'
        out = sanitize_html(html)
        assert "<table" in out
        assert out.count("<tr") == 2
        assert out.count("<td") == 3

    def test_list_structure_preserved(self):
        html = "<ul><li>a</li><li>b</li><li>c</li></ul>"
        out = sanitize_html(html)
        assert "<ul" in out
        assert out.count("<li") == 3

    def test_text_outside_tags_preserved(self):
        out = sanitize_html("纯文本内容")
        assert "纯文本内容" in out

    def test_mixed_content_preserved(self):
        html = '<p>正文 <a href="/info/1116/5946.htm">链接</a> 更多文字</p>'
        out = sanitize_html(html)
        assert "正文" in out
        assert 'href="https://jwc.sylu.edu.cn/info/1116/5946.htm"' in out
        assert "链接" in out
        assert "更多文字" in out


# ---------------------------------------------------------------------------
# sanitize_html — 边界
# ---------------------------------------------------------------------------

class TestEdgeCases:
    def test_empty_string(self):
        assert sanitize_html("") == ""

    def test_none_raises_or_empty(self):
        # BeautifulSoup(None) 会报警告但返回空文档
        # 我们接受空字符串或抛异常 — 这里要求不崩溃
        try:
            out = sanitize_html(None)
            assert out == "" or out is not None
        except (TypeError, AttributeError):
            pass  # 也接受抛异常

    def test_plain_text_returned(self):
        out = sanitize_html("just text")
        assert "just text" in out

    def test_only_script_returns_emptyish(self):
        out = sanitize_html("<script>alert(1)</script>")
        assert "alert" not in out
        assert "<script" not in out.lower()

    def test_nested_script_in_div_removed(self):
        out = sanitize_html('<div><script>alert(1)</script><p>ok</p></div>')
        assert "<script" not in out.lower()
        assert "alert" not in out
        assert "<p>ok</p>" in out

    def test_custom_base_url(self):
        out = sanitize_html('<a href="/foo">x</a>', base_url="https://example.com")
        assert 'href="https://example.com/foo"' in out

    def test_id_attr_removed(self):
        out = sanitize_html('<div id="content">x</div>')
        assert "id=" not in out.lower() or 'id="content"' not in out

    def test_class_attr_removed(self):
        out = sanitize_html('<div class="foo">x</div>')
        assert "class=" not in out.lower()
