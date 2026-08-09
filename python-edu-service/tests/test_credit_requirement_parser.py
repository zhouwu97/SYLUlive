"""学分要求页面解析器测试。

覆盖模块解析、提高课程分离、结构变化保护和边界情况。"""

import httpx
import pytest
from services.crawler import (
    ACADEMIC_REQUIREMENT_QUERY_URL,
    ACADEMIC_REQUIREMENT_URL,
    EduCrawler,
    parse_credit_requirement_html,
    parse_credit_requirement_json,
)


def _minimal_page(content: str = "") -> str:
    if not content:
        content = """
        通识教育理论必修
        要求最低 61.5 学分
        已获得 65 学分
        21 门
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>建议修读学年</th><th>建议修读学期</th><th>实际修读学年</th><th>实际修读学期</th><th>选必修</th><th>成绩</th><th>状态</th><th>备注</th></tr>
          <tr><td>215400043</td><td>大学生心理健康指导</td><td>2</td><td>2024-2025</td><td>1</td><td>2024-2025</td><td>1</td><td>通识教育理论必修</td><td>良好</td><td>已修读</td><td></td></tr>
        </table>
        """
    return f"<html><body>{content}</body></html>"


# ============== 正常解析 ==============

def test_parse_multiple_normal_modules():
    """测试多个普通模块的解析。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 61.5 学分
        已获得 65 学分
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>成绩</th><th>状态</th></tr>
          <tr><td>215400001</td><td>大学外语1</td><td>4</td><td>68.9</td><td>已修读</td></tr>
        </table>
        美育模块（限选）
        要求最低 2 学分
        已获得 3 学分
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>成绩</th><th>状态</th></tr>
          <tr><td>215400100</td><td>艺术鉴赏</td><td>2</td><td>90</td><td>已修读</td></tr>
        </table>
    """)
    result = parse_credit_requirement_html(html)
    assert result["success"] is True
    assert result["status"] == "available"
    assert len(result["modules"]) == 2
    assert result["modules"][0]["name"] == "通识教育理论必修"
    assert result["modules"][0]["required_credits"] == 61.5
    assert result["modules"][0]["earned_credits"] == 65
    assert result["modules"][1]["name"] == "美育模块（限选）"


def test_parse_module_with_decimal_credits():
    """测试学分为小数的情况。"""
    html = _minimal_page("""
        自然模块
        要求最低 4.5 学分
        已获得 3.0 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["success"] is True
    mod = result["modules"][0]
    assert mod["required_credits"] == 4.5
    assert mod["earned_credits"] == 3.0


def test_parse_module_with_integer_credits():
    """测试学分为整数的情况。"""
    html = _minimal_page("""
        体育模块
        要求最低 4 学分
        已获得 4 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["required_credits"] == 4
    assert result["modules"][0]["earned_credits"] == 4


def test_parse_module_with_required_course_count():
    """测试最低门数存在的情况。"""
    html = _minimal_page("""
        三选一模块
        要求最低 1 门
        已获得 1 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["required_course_count"] == 1


# ============== 状态判断 ==============

def test_completed_module():
    """测试已满足状态的模块。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 61.5 学分
        已获得 65 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["status"] == "completed"


def test_shortfall_module():
    """测试完全未修的模块。"""
    html = _minimal_page("""
        某模块
        要求最低 30 学分
        已获得 0 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["status"] == "shortfall"


def test_in_progress_module():
    """测试进行中的模块。"""
    html = _minimal_page("""
        某模块
        要求最低 10 学分
        已获得 8 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["status"] == "in_progress"


def test_unknown_status_when_no_requirement():
    """测试没有最低要求时的状态。"""
    html = _minimal_page("""
        其他模块
        已获得 5 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["status"] == "unknown"


# ============== 提高课程 ==============

def test_improvement_courses_separated():
    """测试提高课程被正确分离到 improvement_courses。"""
    html = _minimal_page("""
        提高课程
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>成绩</th><th>状态</th></tr>
          <tr><td>215400200</td><td>大学外语提高</td><td>2</td><td>86.9</td><td>已修读</td></tr>
        </table>
    """)
    result = parse_credit_requirement_html(html)
    assert len(result["modules"]) == 0
    assert len(result["improvement_courses"]) >= 1
    assert result["improvement_courses"][0]["course_name"] == "大学外语提高"


# ============== 成绩类型 ==============

def test_numeric_grade():
    """测试数字成绩。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 10 学分
        已获得 10 学分
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>成绩</th><th>状态</th></tr>
          <tr><td>001</td><td>高数</td><td>4</td><td>85</td><td>已修读</td></tr>
        </table>
    """)
    result = parse_credit_requirement_html(html)
    course = result["modules"][0]["courses"][0]
    assert course["grade"] == "85"


def test_letter_grade():
    """测试等级成绩（优秀、良好等）。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 10 学分
        已获得 10 学分
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>成绩</th><th>状态</th></tr>
          <tr><td>001</td><td>思政课</td><td>2</td><td>良好</td><td>已修读</td></tr>
        </table>
    """)
    result = parse_credit_requirement_html(html)
    course = result["modules"][0]["courses"][0]
    assert course["grade"] == "良好"


# ============== 字段处理 ==============

def test_empty_remark_not_present_in_output():
    """测试备注为空时不影响解析。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 10 学分
        已获得 10 学分
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>成绩</th><th>状态</th><th>备注</th></tr>
          <tr><td>001</td><td>某课程</td><td>2</td><td>80</td><td>已修读</td><td></td></tr>
        </table>
    """)
    result = parse_credit_requirement_html(html)
    course = result["modules"][0]["courses"][0]
    assert course["remark"] is None


def test_suggested_vs_actual_term_differ():
    """测试建议学期与实际学期不同时的处理。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 10 学分
        已获得 10 学分
        <table>
          <tr><th>课程号</th><th>课程名称</th><th>课程学分</th><th>建议修读学年</th><th>建议修读学期</th><th>实际修读学年</th><th>实际修读学期</th><th>成绩</th><th>状态</th></tr>
          <tr><td>001</td><td>某课程</td><td>2</td><td>2025-2026</td><td>1</td><td>2026-2027</td><td>1</td><td>80</td><td>已修读</td></tr>
        </table>
    """)
    result = parse_credit_requirement_html(html)
    course = result["modules"][0]["courses"][0]
    assert course["suggested_year"] == "2025-2026"
    assert course["actual_year"] == "2026-2027"


# ============== 错误与边界 ==============

def test_login_page_returns_failure():
    """测试登录页重定向返回失败。"""
    html = "<html><body>login_slogin 统一身份认证</body></html>"
    result = parse_credit_requirement_html(html)
    assert result["success"] is False
    assert result["status"] == "empty"


def test_empty_page_returns_failure():
    """测试空页面返回失败。"""
    result = parse_credit_requirement_html("")
    assert result["success"] is False


def test_no_modules_no_courses_returns_parse_failed():
    """测试有标题但无模块内容的页面返回 parse_failed。"""
    html = "<html><body><p>学籍预警</p></body></html>"
    result = parse_credit_requirement_html(html)
    assert result["success"] is False
    assert result["status"] in ("empty", "parse_failed")


def test_module_without_courses_table():
    """测试页面只有模块标题但无课程明细。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 61.5 学分
        已获得 65 学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["success"] is True
    mod = result["modules"][0]
    assert mod["name"] == "通识教育理论必修"
    assert len(mod["courses"]) == 0


def test_fullwidth_symbols_normalized():
    """测试全角符号和多余空格不会影响解析。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低　　61.5　学分
        已获得　　65　学分
    """)
    result = parse_credit_requirement_html(html)
    assert result["modules"][0]["required_credits"] == 61.5


def test_structure_signature_present():
    """测试结构签名存在。"""
    html = _minimal_page()
    result = parse_credit_requirement_html(html)
    assert len(result["structure_signature"]) == 64


def test_query_context_extraction():
    """测试查询上下文（学院、年级、专业）的提取。"""
    html = _minimal_page("""
        通识教育理论必修
        要求最低 10 学分
        已获得 10 学分
        学院：信息科学与工程学院
        年级：2024
        专业：通信工程(0306)
    """)
    result = parse_credit_requirement_html(html)
    ctx = result["query_context"]
    assert ctx["college_name"] == "信息科学与工程学院"
    assert ctx["enrollment_grade"] == "2024"
    assert ctx["major_name"] == "通信工程(0306)"


def test_parser_version():
    """测试解析器版本号。"""
    result = parse_credit_requirement_html(_minimal_page())
    assert result["parser_version"] == "credit-requirement-v2"


# ============== 真实 JSON 查询协议 ==============

def _credit_requirement_json():
    return [
        {
            "xfyqjd_id": "module-1",
            "xfyqjdmc": "美育模块（限选）",
            "yqzdxf": "2",
            "kczdms": "1",
            "jdkcsx": "1",
            "kcList": [
                {
                    "kch": "001",
                    "kcmc": "音乐鉴赏",
                    "xf": "1.5",
                    "jyxdxnmc": "2024-2025",
                    "jyxdxqmc": "1",
                    "xnmc": "2024-2025",
                    "xqmc": "2",
                    "xbx": "通识教育理论选修",
                    "cj": "优秀",
                    "bfzcj": "90",
                    "tdbj": "0",
                    "yxxf": "1.5",
                }
            ],
        },
        {
            "xfyqjd_id": "improvement",
            "xfyqjdmc": "提高课程",
            "yqzdxf": "0",
            "kczdms": "0",
            "jdkcsx": "1",
            "kcList": [
                {
                    "kch": "002",
                    "kcmc": "大学外语提高",
                    "xf": "2",
                    "xnmc": "2025-2026",
                    "xqmc": "2",
                    "xbx": "通识教育理论选修",
                    "cj": "86.9",
                    "bfzcj": "86.9",
                    "tdbj": "0",
                    "yxxf": "2",
                }
            ],
        },
    ]


def test_parse_credit_requirement_json_tree():
    result = parse_credit_requirement_json(
        _credit_requirement_json(),
        query_context={
            "college_name": "信息科学与工程学院",
            "enrollment_grade": "2024",
            "major_name": "通信工程(0306)",
        },
    )

    assert result["success"] is True
    assert result["status"] == "available"
    assert len(result["modules"]) == 1
    assert len(result["improvement_courses"]) == 1

    module = result["modules"][0]
    assert module["name"] == "美育模块（限选）"
    assert module["required_credits"] == 2
    assert module["required_course_count"] == 1
    assert module["earned_credits"] == 1.5
    assert module["completed_course_count"] == 1
    assert module["status"] == "in_progress"
    assert module["is_optional"] is True

    course = module["courses"][0]
    assert course["course_code"] == "001"
    assert course["course_name"] == "音乐鉴赏"
    assert course["suggested_year"] == "2024-2025"
    assert course["actual_semester"] == "2"
    assert course["raw_status"] == "通过"
    assert course["completed"] is True


def test_rule_nodes_use_their_parent_module_title():
    """规则分支不应在首页伪装成独立模块，专业名称必须来自接口树。"""
    payload = [
        {
            "xfyqjd_id": "major-elective",
            "xfyqjdmc": "专业教育理论选修",
            "yqzdxf": "17.75",
            "kczdms": "0",
            "kcList": [],
            "xfyqjdList": [
                {
                    "xfyqjd_id": "rule-a",
                    "xfyqjdmc": "至少修1.75学分",
                    "yqzdxf": "1.75",
                    "kcList": [
                        {
                            "kch": "A1",
                            "kcmc": "专业选修 A",
                            "xf": "1.75",
                            "yxxf": "1.75",
                            "cj": "90",
                            "bfzcj": "90",
                        }
                    ],
                },
                {
                    "xfyqjd_id": "rule-b",
                    "xfyqjdmc": "至少修2.5学分",
                    "yqzdxf": "2.5",
                    "kcList": [],
                },
            ],
        }
    ]

    result = parse_credit_requirement_json(payload)

    assert [module["name"] for module in result["modules"]] == ["专业教育理论选修"]
    assert result["modules"][0]["courses"][0]["course_name"] == "专业选修 A"
    assert result["modules"][0]["earned_credits"] == 1.75


@pytest.mark.asyncio
async def test_fetch_credit_requirements_uses_ajax_query_protocol():
    entry_html = """
    <html><body>
      <form id="searchForm">
        <select name="jg_id"><option value="college" selected>某学院</option></select>
        <select name="njdm_id"><option value="2024" selected>2024</option></select>
        <select name="zyh_id"><option value="major" selected>某专业</option></select>
        <button id="search_go" type="button">查询</button>
      </form>
    </body></html>
    """
    requests = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if str(request.url).startswith(ACADEMIC_REQUIREMENT_URL):
            return httpx.Response(200, text=entry_html, request=request)
        if str(request.url) == ACADEMIC_REQUIREMENT_QUERY_URL:
            return httpx.Response(200, json=_credit_requirement_json(), request=request)
        return httpx.Response(404, request=request)

    crawler = EduCrawler()
    crawler.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        result = await crawler.fetch_credit_requirements("session-cookie")
    finally:
        await crawler.client.aclose()

    assert result["success"] is True
    assert len(result["modules"]) == 1
    assert len(requests) == 2
    assert requests[1].method == "POST"
    assert str(requests[1].url) == ACADEMIC_REQUIREMENT_QUERY_URL
    assert requests[1].headers["x-requested-with"] == "XMLHttpRequest"
    assert requests[1].content == b"jg_id=college&njdm_id=2024&zyh_id=major"


@pytest.mark.asyncio
async def test_fetch_credit_requirements_rejects_unselected_query_fields():
    """查询表单没有当前选项时，不能错误地回退到第一项专业。"""
    entry_html = """
    <html><body>
      <form id="searchForm">
        <select name="jg_id"><option value="college-a">甲学院</option><option value="college-b">乙学院</option></select>
        <select name="njdm_id"><option value="2023">2023</option><option value="2024">2024</option></select>
        <select name="zyh_id"><option value="major-a">甲专业</option><option value="major-b">乙专业</option></select>
      </form>
    </body></html>
    """
    requests = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if str(request.url).startswith(ACADEMIC_REQUIREMENT_URL):
            return httpx.Response(200, text=entry_html, request=request)
        return httpx.Response(500, request=request)

    crawler = EduCrawler()
    crawler.client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        result = await crawler.fetch_credit_requirements("session-cookie")
    finally:
        await crawler.client.aclose()

    assert result["success"] is False
    assert result["status"] == "query_protocol_changed"
    assert result["error_code"] == "CREDIT_REQUIREMENT_QUERY_PROTOCOL_CHANGED"
    assert len(requests) == 1


def test_source_url():
    """测试源 URL。"""
    result = parse_credit_requirement_html(_minimal_page())
    assert result["source_url"] == "/xjyj/xjyj_cxXjyjIndex.html"
