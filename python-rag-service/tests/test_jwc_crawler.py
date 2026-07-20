from app.crawlers.sylu_jwc.article_parser import parse_article, parse_list
from app.crawlers.sylu_jwc.catalog import CATEGORY_CONFIG
from app.crawlers.sylu_jwc.fetcher import validate_url
from app.crawlers.sylu_jwc.fetcher import FetchResult
from app.crawlers.sylu_jwc.attachment_resolver import resolve_attachment
from app.crawlers.sylu_jwc.privacy_guard import scan


def test_list_parser_discovers_reverse_pagination_and_dynamic_category_id():
    html = '''
    <ul><li><span>2025-08-28</span><a href="info/1121/5666.htm"><em>重修管理办法</em></a></li></ul>
    <div class="p_pages"><a href="jxglwj/1.htm">尾页</a></div>
    '''.encode("utf-8")
    items, pages = parse_list(html, CATEGORY_CONFIG["jxglwj"], "https://jwc.sylu.edu.cn/jxglwj.htm")
    assert items[0].category_id == "1121"
    assert items[0].source_article_id == "5666"
    assert pages == ["https://jwc.sylu.edu.cn/jxglwj/1.htm"]


def test_article_parser_keeps_attachment_metadata_without_publishing_content():
    listing = parse_list(
        '<a href="info/1121/5666.htm">管理办法</a>'.encode("utf-8"),
        CATEGORY_CONFIG["jxglwj"],
        "https://jwc.sylu.edu.cn/jxglwj.htm",
    )[0][0]
    html = '''
    <div class="main_contit"><h2>管理办法</h2><p>作者:教务管理科 时间：2025-08-28</p></div>
    <div class="v_news_content"><p>正文</p><a href="/system/_content/download.jsp?wbfileid=1">办法.pdf</a></div>
    '''.encode("utf-8")
    item = parse_article(html, listing, listing.source_url)
    assert item["content_text"] == "正文"
    assert item["attachments"][0]["url"].startswith("https://jwc.sylu.edu.cn/")


def test_fetcher_rejects_external_hosts_and_privacy_scan_is_conservative():
    try:
        validate_url("https://example.com/a")
    except ValueError:
        pass
    else:
        raise AssertionError("external host must be rejected")
    assert scan("成绩公示 学号 2026010101")[0]


def test_attachment_resolver_marks_download_captcha_instead_of_indexing_html():
    class FakeFetcher:
        def get(self, url, max_bytes):
            return FetchResult(url, "请输入验证码 codeValue".encode("utf-8"), "text/html", 200)

    result = resolve_attachment({"name": "附件", "url": "https://jwc.sylu.edu.cn/system/_content/download.jsp?wbfileid=1", "extension": "pdf"}, FakeFetcher())
    assert result["parse_status"] == "blocked_captcha"
    assert result["detected_mime"] == "text/html"
