"""测试 jwc_public_crawler — 列表解析、详情解析、content_hash、停止条件。

所有测试使用 fixture HTML，不访问真实网络。
"""
import os
from pathlib import Path

import pytest
from unittest.mock import AsyncMock, patch

from services.jwc_public_crawler import (
    parse_list_page,
    parse_total_pages,
    build_page_url,
    parse_article_detail,
    _compute_content_hash,
    _extract_article_id,
    _resolve,
    JWCPublicCrawler,
    ListItem,
)

FIXTURES = Path(__file__).parent / "fixtures" / "jwc"


def read_fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


# ── URL 解析 ─────────────────────────────────────────────────────


class TestResolve:
    def test_root_relative(self):
        assert _resolve("/info/1116/5946.htm") == \
            "https://jwc.sylu.edu.cn/info/1116/5946.htm"

    def test_page_relative(self):
        assert _resolve("5946.htm", "https://jwc.sylu.edu.cn/info/1116/") == \
            "https://jwc.sylu.edu.cn/info/1116/5946.htm"

    def test_absolute_preserved(self):
        assert _resolve("https://example.com") == "https://example.com"


class TestExtractArticleId:
    def test_normal(self):
        assert _extract_article_id("https://jwc.sylu.edu.cn/info/1116/5946.htm") == "5946"

    def test_no_match(self):
        assert _extract_article_id("https://jwc.sylu.edu.cn/") == ""


# ── 列表页解析 ────────────────────────────────────────────────────


class TestParseListPage:
    def test_parses_list_items(self):
        html = read_fixture("jwtz_page1.html")
        items = parse_list_page(html, "https://jwc.sylu.edu.cn/jwtz.htm")
        assert len(items) >= 2
        assert items[0].title == "关于做好NCRE报名工作的通知"
        assert items[0].source_article_id == "5946"
        assert "jwc.sylu.edu.cn" in items[0].source_url

    def test_publish_date_extracted(self):
        html = read_fixture("jwtz_page1.html")
        items = parse_list_page(html, "https://jwc.sylu.edu.cn/jwtz.htm")
        assert items[0].publish_date == "2026-06-23"

    def test_url_is_absolute(self):
        html = read_fixture("jwtz_page1.html")
        items = parse_list_page(html, "https://jwc.sylu.edu.cn/jwtz.htm")
        for item in items:
            assert item.source_url.startswith("https://")


class TestParseTotalPages:
    def test_extracts_from_pagination(self):
        html = read_fixture("jwtz_page1.html")
        total = parse_total_pages(html)
        assert total >= 2

    def test_no_pagination_returns_one(self):
        total = parse_total_pages("<html></html>")
        assert total == 1


class TestBuildPageUrl:
    def test_page1(self):
        assert build_page_url("jwtz", 1, 140) == \
            "https://jwc.sylu.edu.cn/jwtz.htm"

    def test_page2(self):
        assert build_page_url("jwtz", 2, 140) == \
            "https://jwc.sylu.edu.cn/jwtz/139.htm"

    def test_last_page(self):
        assert build_page_url("jwtz", 140, 140) == \
            "https://jwc.sylu.edu.cn/jwtz/1.htm"


# ── 文章详情解析 ──────────────────────────────────────────────────


class TestParseArticleDetail:
    def test_text_article(self):
        html = read_fixture("article_text.html")
        detail = parse_article_detail(
            html,
            source_url="https://jwc.sylu.edu.cn/info/1116/5946.htm",
            category_slug="jwtz",
            category_name="教务通知",
            category_id="1116",
        )
        assert detail is not None
        assert detail.title == "关于做好NCRE报名工作的通知"
        assert detail.publish_date == "2026-06-23"
        assert detail.author_department == "教务管理科"
        assert "各学院" in detail.content_text
        assert detail.content_html  # 清洗后非空
        assert detail.attachments == []
        assert detail.has_attachment is False
        assert len(detail.content_hash) == 64

    def test_attachment_article(self):
        html = read_fixture("article_attachment.html")
        detail = parse_article_detail(
            html,
            source_url="https://jwc.sylu.edu.cn/info/1116/5945.htm",
            category_slug="jwtz",
            category_name="教务通知",
            category_id="1116",
        )
        assert detail is not None
        assert detail.has_attachment is True
        assert len(detail.attachments) == 1
        assert detail.attachments[0]["name"] == "期末考试安排.xls"
        assert detail.attachments[0]["extension"] == "xls"
        assert "download.jsp" in detail.attachments[0]["url"]


# ── content_hash ──────────────────────────────────────────────────


class TestContentHash:
    def test_hash_is_sha256_hex(self):
        h = _compute_content_hash(
            "title", "2026-06-23", "部门",
            "<p>content</p>", [],
        )
        assert len(h) == 64
        assert all(c in "0123456789abcdef" for c in h)

    def test_hash_stable_for_same_input(self):
        h1 = _compute_content_hash("a", "b", "c", "<p>d</p>", [])
        h2 = _compute_content_hash("a", "b", "c", "<p>d</p>", [])
        assert h1 == h2

    def test_hash_changes_for_different_title(self):
        h1 = _compute_content_hash("a", "b", "c", "<p>d</p>", [])
        h2 = _compute_content_hash("z", "b", "c", "<p>d</p>", [])
        assert h1 != h2

    def test_hash_changes_for_different_attachment(self):
        h1 = _compute_content_hash("a", "b", "c", "<p>d</p>",
                                    [{"name": "x.pdf", "url": "https://jwc.sylu.edu.cn/x"}])
        h2 = _compute_content_hash("a", "b", "c", "<p>d</p>", [])
        assert h1 != h2

    def test_attachment_order_independent(self):
        h1 = _compute_content_hash("a", "b", "c", "<p>d</p>", [
            {"name": "a.pdf", "url": "https://jwc.sylu.edu.cn/a"},
            {"name": "b.pdf", "url": "https://jwc.sylu.edu.cn/b"},
        ])
        h2 = _compute_content_hash("a", "b", "c", "<p>d</p>", [
            {"name": "b.pdf", "url": "https://jwc.sylu.edu.cn/b"},
            {"name": "a.pdf", "url": "https://jwc.sylu.edu.cn/a"},
        ])
        assert h1 == h2


# ── 404 处理 ──────────────────────────────────────────────────────


class TestArticle404:
    def test_404_returns_none(self):
        detail = parse_article_detail(
            "", "", "", "", "", fetch_status=404,
        )
        assert detail is None


# ── HTML 安全 ─────────────────────────────────────────────────────


class TestHtmlSafety:
    def test_script_removed_from_content(self):
        html = """<div class="v_news_content">
            <p>ok</p><script>alert(1)</script>
        </div>"""
        detail = parse_article_detail(
            f"<form><div class='main_contit'><h2>T</h2></div>{html}</form>",
            "https://jwc.sylu.edu.cn/info/1116/9999.htm",
            "jwtz", "教务通知", "1116",
        )
        assert detail is not None
        assert "<script" not in detail.content_html.lower()
        assert "alert" not in detail.content_html

    def test_onclick_removed(self):
        html = """<div class="v_news_content">
            <a href="info/1116/1.htm" onclick="bad()">link</a>
        </div>"""
        detail = parse_article_detail(
            f"<form><div class='main_contit'><h2>T</h2></div>{html}</form>",
            "https://jwc.sylu.edu.cn/info/1116/9999.htm",
            "jwtz", "教务通知", "1116",
        )
        assert detail is not None
        assert "onclick" not in detail.content_html.lower()

    def test_javascript_href_removed(self):
        html = """<div class="v_news_content">
            <a href="javascript:alert(1)">bad link</a>
        </div>"""
        detail = parse_article_detail(
            f"<form><div class='main_contit'><h2>T</h2></div>{html}</form>",
            "https://jwc.sylu.edu.cn/info/1116/9999.htm",
            "jwtz", "教务通知", "1116",
        )
        assert detail is not None
        assert "javascript:" not in detail.content_html.lower()


# ── 增量模式停止条件 ───────────────────────────────────────────────


class TestStopCondition:
    """验证停止条件逻辑（通过检查 crawl_category 的返回）

    因为 crawl_category 依赖网络，这里通过 mock _fetch 和 parse_list_page 来模拟。
    """

    @pytest.mark.asyncio
    async def test_stops_on_full_page_known(self):
        """当一整页全为已知文章时停止。"""
        # 模拟 fetch 返回已知文章列表
        from services import jwc_public_crawler as mod
        items = [
            ListItem("T1", "2026-06-23",
                     "https://jwc.sylu.edu.cn/info/1116/5900.htm", "5900"),
            ListItem("T2", "2026-06-22",
                     "https://jwc.sylu.edu.cn/info/1116/5901.htm", "5901"),
        ]
        known = {
            "https://jwc.sylu.edu.cn/info/1116/5900.htm",
            "https://jwc.sylu.edu.cn/info/1116/5901.htm",
        }

        with patch.object(mod, "_fetch", new_callable=AsyncMock) as mock_fetch:
            mock_fetch.return_value = (200, "<html></html>")
            with patch.object(mod, "parse_list_page", return_value=items):
                with patch.object(mod, "parse_total_pages", return_value=2):
                    async with __import__("httpx").AsyncClient() as client:
                        from services.jwc_public_crawler import crawl_category
                        result = await crawl_category(
                            client, "jwtz", known, max_pages=3, reconcile=False,
                        )
                        assert result.stop_reason == "full_page_known"
                        assert len(result.items) == 0


# ── reconcile 模式 ────────────────────────────────────────────────


class TestReconcileMode:
    @pytest.mark.asyncio
    async def test_reconcile_forces_single_page(self):
        from services import jwc_public_crawler as mod
        items = [
            ListItem("T1", "2026-06-23",
                     "https://jwc.sylu.edu.cn/info/1116/5900.htm", "5900"),
        ]
        known = {"https://jwc.sylu.edu.cn/info/1116/5900.htm"}

        mock_detail = __import__("services.jwc_public_crawler", fromlist=["ArticleDetail"])
        article = mock_detail.ArticleDetail(
            source_url="https://jwc.sylu.edu.cn/info/1116/5900.htm",
            title="T1", publish_date="2026-06-23",
            author_department="", content_html="<p>x</p>",
            content_text="x", attachments=[],
            has_attachment=False,
            content_hash="a" * 64,
            fetch_status=200,
        )

        with patch.object(mod, "_fetch", new_callable=AsyncMock) as mock_fetch:
            mock_fetch.return_value = (200, "<html></html>")
            with patch.object(mod, "parse_list_page", return_value=items):
                with patch.object(mod, "parse_total_pages", return_value=2):
                    with patch.object(mod, "parse_article_detail", return_value=article):
                        async with __import__("httpx").AsyncClient() as client:
                            from services.jwc_public_crawler import crawl_category
                            result = await crawl_category(
                                client, "jwtz", known, max_pages=3, reconcile=True,
                            )
                            # reconcile 模式：即使全部已知也重新抓
                            assert result.stop_reason == "reconcile_first_page"
                            assert len(result.items) == 1


# ── 抓取规则 ──────────────────────────────────────────────────────


class TestCrawlRules:
    @pytest.mark.asyncio
    async def test_single_category_failure_does_not_block_other(self):
        """如果 jwgg 完全失败，jwtz 数据应该仍然返回。"""
        crawler = JWCPublicCrawler()

        # mock _fetch 让 jwtz 成功、jwgg 失败
        original_fetch = __import__("services.jwc_public_crawler", fromlist=["_fetch"])

        call_count = {"count": 0}

        async def mock_fetch(client, url, **kwargs):
            call_count["count"] += 1
            if "jwgg" in url:
                return (503, "Service Unavailable")
            if "jwtz" in url or "1116" in url:
                return (200, read_fixture("jwtz_page1.html"))
            return (200, read_fixture("article_text.html"))

        with patch("services.jwc_public_crawler._fetch", side_effect=mock_fetch):
            result = await crawler.crawl(
                categories=["jwtz", "jwgg"],
                known_source_urls={},
                max_pages=1,
            )
            # jwtz 应该有数据
            assert result["stats"]["partial_failure"] is True
            assert result["stats"]["categories_requested"] == 2
            # 至少 jwtz 有数据
            assert result["stats"]["list_items_seen"] > 0


class TestContentHashInResponse:
    @pytest.mark.asyncio
    async def test_items_have_sha256_hash(self):
        crawler = JWCPublicCrawler()

        async def mock_fetch(client, url, **kwargs):
            if "info/1116" in url and "5946" in url:
                return (200, read_fixture("article_text.html"))
            return (200, read_fixture("jwtz_page1.html"))

        with patch("services.jwc_public_crawler._fetch", side_effect=mock_fetch):
            result = await crawler.crawl(
                categories=["jwtz"],
                known_source_urls={},
                max_pages=1,
            )
            for item in result["items"]:
                assert len(item["content_hash"]) == 64
                assert all(c in "0123456789abcdef" for c in item["content_hash"])
