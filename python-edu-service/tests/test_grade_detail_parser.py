import pytest

from services.crawler import EduCrawler, parse_grade_detail_response


DETAIL_HTML = """
<table>
  <tr><th>成绩分项</th><th>成绩分项比例</th><th>成绩</th></tr>
  <tr><td>【 平时 】</td><td>15%</td><td>98</td></tr>
  <tr><td>【作业】</td><td>15%</td><td>88</td></tr>
  <tr><td>【实验】</td><td>10%</td><td>81.8</td></tr>
  <tr><td>【期末】</td><td>60%</td><td>40</td></tr>
  <tr><td>【总评】</td><td></td><td>60.1</td></tr>
</table>
"""


def test_parse_grade_detail_html_table():
    detail = parse_grade_detail_response(DETAIL_HTML, "电磁场与电磁波")

    assert detail["success"] is True
    assert detail["course_name"] == "电磁场与电磁波"
    assert detail["total_grade"] == "60.1"
    assert detail["components"] == [
        {"name": "平时", "weight": "15%", "score": "98"},
        {"name": "作业", "weight": "15%", "score": "88"},
        {"name": "实验", "weight": "10%", "score": "81.8"},
        {"name": "期末", "weight": "60%", "score": "40"},
        {"name": "总评", "weight": None, "score": "60.1"},
    ]


def test_parse_grade_detail_json_items():
    body = """
    {
      "items": [
        {"cjxmmc": "平时", "xmbfb": "15%", "xmcj": "98"},
        {"cjxmmc": "总评", "xmcj": "60.1"}
      ]
    }
    """

    detail = parse_grade_detail_response(body, "电磁场与电磁波")

    assert detail["success"] is True
    assert detail["total_grade"] == "60.1"
    assert detail["components"][0] == {
        "name": "平时",
        "weight": "15%",
        "score": "98",
    }


@pytest.mark.asyncio
async def test_fetch_grade_detail_uses_official_detail_endpoint():
    class Response:
        status_code = 200
        text = DETAIL_HTML
        headers = {"Content-Type": "text/html;charset=UTF-8"}

    class Client:
        def __init__(self):
            self.posts = []

        async def post(self, url, params=None, data=None, headers=None):
            self.posts.append({
                "url": url,
                "params": params,
                "data": data,
                "headers": headers,
            })
            return Response()

    client = Client()
    crawler = EduCrawler()
    crawler.client = client

    detail = await crawler.fetch_grade_detail(
        cookie="JSESSIONID=test",
        year="2025",
        semester=12,
        class_id="44DE3FFE6E97156BE0630100050AD0D4",
        course_name="电磁场与电磁波",
        course_id="210300504",
        student_grade_id="opaque-xh-id",
    )

    assert detail["success"] is True
    assert detail["total_grade"] == "60.1"
    assert client.posts[0]["url"].endswith("/cjcx_cxCjxqGjh.html")
    assert client.posts[0]["params"] == {"gnmkdm": "N305005"}
    assert client.posts[0]["data"]["jxb_id"] == "44DE3FFE6E97156BE0630100050AD0D4"
    assert client.posts[0]["data"]["xnm"] == "2025"
    assert client.posts[0]["data"]["xqm"] == "12"
    assert client.posts[0]["data"]["xh_id"] == "opaque-xh-id"
    assert client.posts[0]["data"]["kcmc"] == "电磁场与电磁波"
