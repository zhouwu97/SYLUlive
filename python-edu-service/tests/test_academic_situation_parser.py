from services.crawler import parse_academic_situation_html


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


def test_gpa_parsing_continuous_text():
    html = "当前所有课程平均学分绩点（GPA）：2.61728 当前学位课程平均学分绩点（GPA）：1.96826"
    parsed = parse_academic_situation_html(html)
    assert parsed["all_gpa"] == 2.61728
    assert parsed["degree_gpa"] == 1.96826


def test_gpa_parsing_with_spaces():
    html = "当前所有课程平均学分绩点 （GPA） ： 2.61728 当前学位课程平均学分绩点 （GPA） ： 1.96826"
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
    </div>
    """
    parsed = parse_academic_situation_html(html)
    assert parsed["all_gpa"] == 2.61728
    assert parsed["degree_gpa"] == 1.96826
