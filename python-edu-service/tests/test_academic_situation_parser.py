from models.schemas import AcademicSituationResponse
from services.crawler import parse_academic_situation_html


def _valid_summary(
    all_gpa="2.61728",
    degree_gpa="1.96826",
):
    return f"""
      当前所有课程平均学分绩点（GPA）：{all_gpa}
      当前学位课程平均学分绩点（GPA）：{degree_gpa}
      计划总课程 101 门 通过 51 门 未通过 1 门 未修 43 门 在读 6 门
      计划学位课程为 15 门 通过 7 门 未通过 1 门 未修 6 门 在读 1 门
    """


def test_parse_academic_situation_summary_and_retake_passed():
    html = """
    <html>
      <body>
        <div>
          当前所有课程平均学分绩点（GPA）：2.61728
          当前学位课程平均学分绩点（GPA）：1.96826
          计划总课程 101 门 通过 51 门 未通过 1 门 未修 43 门 在读 6 门
          计划学位课程为 15 门 通过 7 门 未通过 1 门 未修 6 门 在读 1 门
        </div>
        <table>
          <tr>
            <th>修读状态</th><th>成绩学年</th><th>学期</th><th>课程号</th>
            <th>课程名称</th><th>学时</th><th>课程性质</th><th>学分</th>
            <th>课程类别</th><th>最大成绩</th><th>绩点</th><th>成绩</th>
            <th>补考</th><th>重修</th><th>建议修读学年</th>
            <th>建议修读学期</th><th>课程重要性质数</th>
          </tr>
          <tr>
            <td>已通过</td><td>2024-2025</td><td>2</td><td>050001</td>
            <td>大学外语1</td><td>64</td><td>学位课</td><td>4</td>
            <td>公共基础课</td><td>68.9</td><td>1.9</td><td>53.4</td>
            <td>--</td><td>68.9</td><td>2024-2025</td>
            <td>1</td><td>1</td>
          </tr>
        </table>
      </body>
    </html>
    """

    parsed = parse_academic_situation_html(html)

    assert parsed["success"] is True
    assert parsed["source_kind"] == "official_academic_situation"
    assert parsed["source_url"] == "/xsxy/xsxyqk_cxXsxyqkIndex.html"
    assert parsed["parser_version"] == "academic-situation-v2"
    assert parsed["captured_at"]
    assert parsed["official_updated_at"] is None
    assert len(parsed["structure_signature"]) == 64
    assert parsed["all_gpa"] == 2.61728
    assert parsed["degree_gpa"] == 1.96826
    assert parsed["total_courses"] == 101
    assert parsed["passed_courses"] == 51
    assert parsed["failed_courses"] == 1
    assert parsed["in_progress_courses"] == 6
    assert parsed["degree_total_courses"] == 15

    course = parsed["courses"][0]
    assert course["course_name"] == "大学外语1"
    assert course["has_retake"] is True
    assert course["effective_passed"] is True
    assert course["effective_grade"] == "68.9"
    assert course["is_degree"] is True
    assert parsed["courses_status"] == "available"


def test_gpa_parsing_continuous_text():
    html = _valid_summary()
    parsed = parse_academic_situation_html(html)
    assert parsed["all_gpa"] == 2.61728
    assert parsed["degree_gpa"] == 1.96826


def test_gpa_parsing_with_spaces():
    html = f"""
      当前所有课程平均学分绩点 （GPA） ： 2.61728
      当前学位课程平均学分绩点 （GPA） ： 1.96826
      计划总课程 101 门 通过 51 门 未通过 1 门 未修 43 门 在读 6 门
      计划学位课程为 15 门 通过 7 门 未通过 1 门 未修 6 门 在读 1 门
    """
    parsed = parse_academic_situation_html(html)
    assert parsed["all_gpa"] == 2.61728
    assert parsed["degree_gpa"] == 1.96826


def test_gpa_parsing_with_html_tags():
    html = """
    <div>
      当前所有课程平均学分绩点
      <!-- 当前所有课程平均学分绩点 -->
      <font>（GPA）：</font>
      <font style="color:red;">2.61728</font>
      当前学位课程平均学分绩点
      <font>（GPA）：</font>
      <font style="color:red;">1.96826</font>
      计划总课程 101 门 通过 51 门 未通过 1 门 未修 43 门 在读 6 门
      计划学位课程为 15 门 通过 7 门 未通过 1 门 未修 6 门 在读 1 门
    </div>
    """
    parsed = parse_academic_situation_html(html)
    assert parsed["all_gpa"] == 2.61728
    assert parsed["degree_gpa"] == 1.96826


def test_parse_academic_situation_degree_gpa_with_split_text():
    html = """
    <div>
      当前所有课程平均学分绩点 <font>（GPA）：</font><font>2.61728</font>
      当前学位课 <span>程平均学分绩点</span> <font>（GPA）：</font><font>1.96826</font>
      计划总课程 101 门 通过 51 门 未通过 1 门 未修 43 门 在读 6 门
      计划学位课程为 15 门 通过 7 门 未通过 1 门 未修 6 门 在读 1 门
    </div>
    """
    result = parse_academic_situation_html(html)
    assert result["all_gpa"] == 2.61728
    assert result["degree_gpa"] == 1.96826


def test_blank_and_login_pages_fail_closed():
    for html in ("", '<form action="login_slogin.html">用户登录</form>'):
        result = parse_academic_situation_html(html)

        assert result["success"] is False
        assert result["error_code"] == "ACADEMIC_SITUATION_STRUCTURE_CHANGED"
        assert result["courses_status"] == "parse_failed"
        assert result["total_courses"] is None


def test_missing_gpa_region_fails_closed():
    html = """
      计划总课程 101 门 通过 51 门 未通过 1 门 未修 43 门 在读 6 门
      计划学位课程为 15 门 通过 7 门 未通过 1 门 未修 6 门 在读 1 门
    """

    result = parse_academic_situation_html(html)

    assert result["success"] is False
    assert result["message"] == "学业情况页面结构发生变化"


def test_missing_course_count_region_fails_closed():
    result = parse_academic_situation_html(
        "当前所有课程平均学分绩点（GPA）：2.61728 "
        "当前学位课程平均学分绩点（GPA）：1.96826"
    )

    assert result["success"] is False
    assert result["passed_courses"] is None


def test_courses_status_distinguishes_unresolved_dynamic_source():
    html = f"""
      <div>{_valid_summary()}</div>
      <div id="course-table"></div>
      <script>$.ajax({{url: '/xsxy/course/list'}})</script>
    """

    result = parse_academic_situation_html(html)

    assert result["success"] is True
    assert result["courses"] == []
    assert result["courses_status"] == "dynamic_source_unresolved"


def test_courses_status_distinguishes_empty_and_missing_tables():
    empty_table_html = f"""
      <div>{_valid_summary()}</div>
      <table>
        <tr><td>课程明细</td></tr>
        <tr><th>课程名称</th><th>最大成绩</th><th>修读状态</th></tr>
      </table>
    """

    empty_result = parse_academic_situation_html(empty_table_html)
    missing_result = parse_academic_situation_html(_valid_summary())

    assert empty_result["courses_status"] == "empty"
    assert missing_result["courses_status"] == "not_present"


def test_courses_status_marks_unparseable_rows_as_failed():
    html = f"""
      <div>{_valid_summary()}</div>
      <table>
        <tr><th>课程名称</th><th>最大成绩</th><th>修读状态</th></tr>
        <tr><td></td><td>90</td><td>通过</td></tr>
      </table>
    """

    result = parse_academic_situation_html(html)

    assert result["courses"] == []
    assert result["courses_status"] == "parse_failed"


def test_structure_failure_schema_keeps_statistics_null():
    parsed = parse_academic_situation_html("")

    response = AcademicSituationResponse(**parsed).model_dump(mode="json")

    assert response["success"] is False
    assert response["total_courses"] is None
    assert response["passed_courses"] is None
    assert response["degree_total_courses"] is None
    assert response["courses_status"] == "parse_failed"
    assert response["error_code"] == "ACADEMIC_SITUATION_STRUCTURE_CHANGED"
