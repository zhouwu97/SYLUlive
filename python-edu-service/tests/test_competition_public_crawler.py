"""
比赛通知爬虫 fixture 测试

使用 Phase 0 保存的真实 HTML fixture 验证解析逻辑。
fixture 文件位于 tests/fixtures/competition/。
"""

import os
import re
import pytest
from pathlib import Path

from services.competition_public_crawler import (
    parse_competition_list_page,
    parse_competition_total_pages,
    build_competition_page_url,
    parse_competition_detail,
    _validate_competition_url,
    _is_competition_article_url,
    _extract_article_id,
    _resolve,
    _compute_content_hash,
    COMPETITION_BASE_URL,
    COMPETITION_LIST_URL,
    COMPETITION_ALLOWED_HOST,
    ARTICLE_PATH_PREFIX,
)

FIXTURE_DIR = Path(__file__).parent / "fixtures" / "competition"


def _load_fixture(name: str) -> str:
    """加载 fixture 文件，如果不存在则跳过测试。"""
    path = FIXTURE_DIR / name
    if not path.exists():
        pytest.skip(f"fixture not found: {path}")
    return path.read_text(encoding="utf-8", errors="replace")


# ── 列表页解析 ───────────────────────────────────────────────────


class TestParseListPage:
    """列表页解析测试。"""

    def test_first_page_extracts_items(self):
        """第一页 fixture 能提取标题、日期、详情 URL。"""
        html = _load_fixture("list_page_1.html")
        items = parse_competition_list_page(html, COMPETITION_LIST_URL)

        assert len(items) > 0, "第一页应能提取至少一条文章"

        for item in items:
            # 每条都有标题
            assert item.title, f"标题不应为空: {item}"
            # 日期格式 YYYY-MM-DD
            assert re.match(r"20\d{2}-\d{2}-\d{2}", item.publish_date), \
                f"日期格式错误: {item.publish_date}"
            # URL 属于 cxcyxy.sylu.edu.cn
            assert COMPETITION_ALLOWED_HOST in item.source_url
            # URL 路径包含 /info/1089/
            assert ARTICLE_PATH_PREFIX in item.source_url, \
                f"文章 URL 路径应包含 {ARTICLE_PATH_PREFIX}: {item.source_url}"
            # article_id 非空
            assert item.source_article_id, \
                f"article_id 不应为空: {item}"

    def test_page_4_extracts_items(self):
        """第 4 页 fixture 能正常解析。"""
        page4_url = f"{COMPETITION_BASE_URL}/tztg/28.htm"
        html = _load_fixture("list_page_4.html")
        items = parse_competition_list_page(html, page4_url)

        assert len(items) > 0, "第 4 页应能提取至少一条文章"

        for item in items:
            assert item.title
            assert re.match(r"20\d{2}-\d{2}-\d{2}", item.publish_date)

    def test_navigation_links_excluded(self):
        """导航栏链接不会被当成文章。"""
        html = _load_fixture("list_page_1.html")
        items = parse_competition_list_page(html, COMPETITION_LIST_URL)

        for item in items:
            # 不应包含导航类链接
            assert "javascript:" not in item.source_url
            assert "#" not in item.source_url
            # URL 必须是 /info/1089/ 路径
            assert _is_competition_article_url(item.source_url)

    def test_duplicates_deduplicated(self):
        """重复链接被去重。"""
        html = _load_fixture("list_page_1.html")
        items = parse_competition_list_page(html, COMPETITION_LIST_URL)

        urls = [item.source_url for item in items]
        assert len(urls) == len(set(urls)), "存在重复 URL"

    def test_external_links_rejected(self):
        """外域链接被静默跳过，不中断解析。"""
        # 构造一个含外域链接的 HTML
        html = """
        <html><body>
        <li>2026-06-28 <a href="https://evil.com/info/1089/123.htm">外域链接</a></li>
        <li>2026-06-27 <a href="/info/1089/456.htm">正常链接</a></li>
        </body></html>
        """
        items = parse_competition_list_page(html, COMPETITION_LIST_URL)

        # 外域链接被跳过，只提取到正常链接
        assert len(items) == 1
        assert items[0].source_article_id == "456"
        assert COMPETITION_ALLOWED_HOST in items[0].source_url


# ── 分页测试 ─────────────────────────────────────────────────────


class TestPagination:
    """分页 URL 构建测试。"""

    def test_page_1_url(self):
        """第 1 页 URL 是 /tztg.htm。"""
        url = build_competition_page_url(1, 31)
        assert url == COMPETITION_LIST_URL

    def test_page_2_url(self):
        """第 2 页 URL 是 /tztg/30.htm（total=31）。"""
        url = build_competition_page_url(2, 31)
        assert url == f"{COMPETITION_BASE_URL}/tztg/30.htm"

    def test_page_4_url(self):
        """第 4 页 URL 是 /tztg/28.htm（total=31）。"""
        url = build_competition_page_url(4, 31)
        assert url == f"{COMPETITION_BASE_URL}/tztg/28.htm"

    def test_last_page_url(self):
        """尾页 URL 是 /tztg/1.htm。"""
        url = build_competition_page_url(31, 31)
        assert url == f"{COMPETITION_BASE_URL}/tztg/1.htm"

    def test_total_pages_from_fixture(self):
        """从 fixture 解析总页数。"""
        html = _load_fixture("list_page_1.html")
        total = parse_competition_total_pages(html)
        assert total >= 1, "总页数应 >= 1"


# ── 详情页解析 ───────────────────────────────────────────────────


class TestParseDetail:
    """详情页解析测试。"""

    def test_plain_detail(self):
        """普通正文详情页（detail_plain.html）正常解析。"""
        html = _load_fixture("detail_plain.html")
        source_url = f"{COMPETITION_BASE_URL}/info/1089/3293.htm"

        detail = parse_competition_detail(
            html,
            source_url,
            list_title="测试标题",
            list_date="2026-06-20",
        )

        assert detail is not None
        assert detail.title, "标题不应为空"
        assert detail.content_html, "正文 HTML 不应为空"
        assert detail.content_text, "正文纯文本不应为空"
        assert detail.content_hash, "content_hash 不应为空"
        assert len(detail.content_hash) == 64, "content_hash 应为 64 字符"

    def test_rich_detail(self):
        """富文本详情页（detail_rich.html）正常解析。"""
        html = _load_fixture("detail_rich.html")
        source_url = f"{COMPETITION_BASE_URL}/info/1089/3273.htm"

        detail = parse_competition_detail(
            html,
            source_url,
            list_title="富文本测试标题",
            list_date="2026-06-15",
        )

        assert detail is not None
        assert detail.title, "标题不应为空"
        assert detail.content_html, "正文 HTML 不应为空"
        # 富文本页面正文应较长
        assert len(detail.content_text) > 100, \
            "富文本页面正文应较长"

    def test_detail_with_attachment(self):
        """带附件详情页（detail_with_attachment.html）正常解析附件。"""
        html = _load_fixture("detail_with_attachment.html")
        source_url = f"{COMPETITION_BASE_URL}/info/1089/3285.htm"

        detail = parse_competition_detail(
            html,
            source_url,
            list_title="附件测试标题",
            list_date="2026-06-22",
        )

        assert detail is not None
        assert detail.has_attachment, "应检测到附件"
        assert len(detail.attachments) > 0, "附件列表不应为空"

        for att in detail.attachments:
            assert att["name"], "附件名不应为空"
            assert att["url"], "附件 URL 不应为空"
            assert "download.jsp" in att["url"] or COMPETITION_ALLOWED_HOST in att["url"]

    def test_title_prefers_list_title(self):
        """标题优先使用列表页传入的 list_title。"""
        html = _load_fixture("detail_plain.html")
        source_url = f"{COMPETITION_BASE_URL}/info/1089/3293.htm"

        detail = parse_competition_detail(
            html,
            source_url,
            list_title="这是列表页标题",
            list_date="2026-06-20",
        )

        assert detail is not None
        assert detail.title == "这是列表页标题"

    def test_detail_404_returns_none(self):
        """404 状态返回 None。"""
        detail = parse_competition_detail(
            "<html>not found</html>",
            "https://cxcyxy.sylu.edu.cn/info/1089/999.htm",
            fetch_status=404,
        )
        assert detail is None

    def test_author_department_defaults(self):
        """未提取到部门时默认为"创新创业学院"。"""
        html = '<html><body><div class="v_news_content">正文</div></body></html>'
        source_url = f"{COMPETITION_BASE_URL}/info/1089/3293.htm"

        detail = parse_competition_detail(
            html,
            source_url,
            list_title="测试",
            list_date="2026-06-20",
        )

        assert detail is not None
        assert detail.author_department == "创新创业学院"


# ── URL 校验测试 ─────────────────────────────────────────────────


class TestUrlValidation:
    """URL 校验测试。"""

    def test_valid_competition_url(self):
        """cxcyxy.sylu.edu.cn HTTPS URL 合法。"""
        _validate_competition_url(
            "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm"
        )

    def test_wrong_host_rejected(self):
        """非 cxcyxy 域名被拒绝。"""
        with pytest.raises(ValueError):
            _validate_competition_url(
                "https://jwc.sylu.edu.cn/info/1089/3293.htm"
            )

    def test_http_rejected(self):
        """HTTP 协议被拒绝。"""
        with pytest.raises(ValueError):
            _validate_competition_url(
                "http://cxcyxy.sylu.edu.cn/info/1089/3293.htm"
            )

    def test_credentials_rejected(self):
        """带凭据的 URL 被拒绝。"""
        with pytest.raises(ValueError):
            _validate_competition_url(
                "https://user:pass@cxcyxy.sylu.edu.cn/info/1089/3293.htm"
            )

    def test_empty_url_rejected(self):
        """空 URL 被拒绝。"""
        with pytest.raises(ValueError):
            _validate_competition_url("")

    def test_article_url_detection(self):
        """文章 URL 检测正确。"""
        assert _is_competition_article_url(
            "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm"
        )
        assert not _is_competition_article_url(
            "https://cxcyxy.sylu.edu.cn/tztg.htm"
        )
        assert not _is_competition_article_url(
            "https://jwc.sylu.edu.cn/info/1089/3293.htm"
        )

    def test_extract_article_id(self):
        """文章 ID 提取正确。"""
        assert _extract_article_id(
            "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm"
        ) == "3293"
        assert _extract_article_id(
            "https://cxcyxy.sylu.edu.cn/tztg.htm"
        ) == ""


# ── content_hash 测试 ────────────────────────────────────────────


class TestContentHash:
    """content_hash 测试。"""

    def test_hash_deterministic(self):
        """相同输入产生相同 hash。"""
        h1 = _compute_content_hash(
            "标题", "2026-06-28", "创新创业学院", "<p>正文</p>", []
        )
        h2 = _compute_content_hash(
            "标题", "2026-06-28", "创新创业学院", "<p>正文</p>", []
        )
        assert h1 == h2

    def test_hash_changes_with_title(self):
        """标题不同则 hash 不同。"""
        h1 = _compute_content_hash(
            "标题A", "2026-06-28", "部门", "<p>正文</p>", []
        )
        h2 = _compute_content_hash(
            "标题B", "2026-06-28", "部门", "<p>正文</p>", []
        )
        assert h1 != h2

    def test_hash_is_sha256(self):
        """hash 是 64 字符的 SHA-256。"""
        h = _compute_content_hash(
            "标题", "2026-06-28", "部门", "<p>正文</p>", []
        )
        assert len(h) == 64
        assert re.match(r"^[a-f0-9]{64}$", h)
