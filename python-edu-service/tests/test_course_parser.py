import pytest

from services.crawler import parse_time_sections, parse_weeks
from models.schemas import CourseInfo


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("1-16周(单)", list(range(1, 17, 2))),
        ("2－16周（双）", list(range(2, 17, 2))),
        ("1—2周，4～5周,7至8周,10到11周", [1, 2, 4, 5, 7, 8, 10, 11]),
        ("1，3，5，7周", [1, 3, 5, 7]),
    ],
)
def test_parse_weeks_preserves_legacy_expression_semantics(expression, expected):
    assert parse_weeks(expression) == expected


def test_parse_weeks_rejects_unrecognized_nonempty_expression():
    with pytest.raises(ValueError, match="周次"):
        parse_weeks("每周")


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("3-4节", (3, 4)),
        ("3至4节", (3, 4)),
        ("0304", (3, 4)),
        ("3节", (3, 3)),
    ],
)
def test_parse_time_sections_keeps_real_section_range(expression, expected):
    assert parse_time_sections(expression) == expected


@pytest.mark.parametrize("expression", ["", "上午", "4-3节", "0000"])
def test_parse_time_sections_never_fabricates_first_two_sections(expression):
    with pytest.raises(ValueError):
        parse_time_sections(expression)


def test_course_response_exposes_compatible_section_coordinates():
    course = CourseInfo(
        name="数字图像处理",
        time=3,
        end_time=4,
        week_day=1,
        weeks=[1, 2, 3],
    )

    assert course.model_dump(mode="json") == {
        "name": "数字图像处理",
        "teacher": None,
        "location": None,
        "time": 3,
        "end_time": 4,
        "week_day": 1,
        "weeks": [1, 2, 3],
        "start_section": 3,
        "end_section": 4,
    }
