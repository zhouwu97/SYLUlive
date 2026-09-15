"""课表去重键必须包含周次、老师与地点。

原实现只用 (课程名, 星期, 节次) 做去重键。同一门课"1-8 周在 A 教室 /
9-16 周在 B 教室"或不同老师的两行，这三个字段完全相同，第二行会被当成
重复丢弃，学生课表少一节。
"""

import asyncio
import json

from services.crawler import EduCrawler


class _FakeResponse:
    def __init__(self, status_code: int, text: str):
        self.status_code = status_code
        self.text = text

    def json(self):
        return json.loads(self.text)


class _FakeClient:
    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = 0

    async def post(self, *args, **kwargs):
        self.calls += 1
        if not self._responses:
            raise AssertionError("unexpected extra request")
        return self._responses.pop(0)


def _fetch(kb_list):
    crawler = EduCrawler.__new__(EduCrawler)
    crawler.client = _FakeClient(
        [_FakeResponse(200, json.dumps({"kbList": kb_list}))]
    )
    return asyncio.run(crawler.fetch_courses("cookie", "2026", 3))


def _row(**overrides):
    row = {
        "kcmc": "大学物理",
        "xm": "张老师",
        "cdmc": "A101",
        "jc": "1-2",
        "xqj": "1",
        "zcd": "1-8",
    }
    row.update(overrides)
    return row


def test_same_course_split_across_weeks_and_rooms_is_kept():
    courses = _fetch([
        _row(cdmc="A101", zcd="1-8"),
        _row(cdmc="B202", zcd="9-16"),
    ])

    assert len(courses) == 2
    assert {course.location for course in courses} == {"A101", "B202"}
    assert {course.week_str for course in courses} == {"1-8", "9-16"}


def test_same_course_with_different_teachers_is_kept():
    courses = _fetch([
        _row(xm="张老师"),
        _row(xm="李老师"),
    ])

    assert len(courses) == 2
    assert {course.teacher for course in courses} == {"张老师", "李老师"}


def test_fully_identical_rows_are_still_deduplicated():
    courses = _fetch([_row(), _row()])

    assert len(courses) == 1


def test_distinct_courses_in_same_slot_are_kept():
    courses = _fetch([
        _row(kcmc="大学物理"),
        _row(kcmc="高等数学"),
    ])

    assert len(courses) == 2
