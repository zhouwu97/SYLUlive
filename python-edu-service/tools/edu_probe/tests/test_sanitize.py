"""
Unit tests for sanitize.py — verifies desensitization rules are enforced.
"""

import sys
from pathlib import Path

# Add probe dir to path
PROBE_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROBE_DIR))

from sanitize import (
    sanitize_student_id,
    sanitize_name,
    sanitize_cookie,
    sanitize_grade_item,
    build_field_inventory,
    sanitize_json_for_output,
)


class TestSanitizeStudentId:
    def test_standard_10_digit(self):
        assert sanitize_student_id("2023123456") == "******3456"

    def test_short_id(self):
        assert sanitize_student_id("123") == "****"

    def test_empty_string(self):
        assert sanitize_student_id("") == "****"

    def test_none(self):
        assert sanitize_student_id(None) == "****"

    def test_non_string(self):
        assert sanitize_student_id(12345) == "****"


class TestSanitizeName:
    def test_normal_name(self):
        assert sanitize_name("张三") == "***"

    def test_empty(self):
        assert sanitize_name("") == "***"

    def test_none(self):
        assert sanitize_name(None) == "***"


class TestSanitizeCookie:
    def test_jsessionid_cookie(self):
        result = sanitize_cookie("JSESSIONID=abc123def456; route=xyz789")
        assert "JSESSIONID" in result
        assert "route" in result
        assert "abc123def456" not in result
        assert "xyz789" not in result
        assert "<redacted>" in result

    def test_empty_cookie(self):
        assert sanitize_cookie("") is None

    def test_none_cookie(self):
        assert sanitize_cookie(None) is None


class TestSanitizeGradeItem:
    def test_personal_fields_redacted(self):
        item = {
            "kcmc": "数据结构",
            "xh": "2023123456",
            "xm": "张三",
            "jsxm": "李老师",
            "cj": "85",
            "bfzcj": "85.5",
        }
        result = sanitize_grade_item(item)
        assert result["kcmc"] == "数据结构"
        assert result["xh"] == "******3456"
        assert result["xm"] == "***"
        assert result["jsxm"] == "李老师"  # teachers kept locally
        assert result["cj"] == "85"

    def test_non_personal_fields_preserved(self):
        item = {"kcmc": "测试课", "xf": "3.0", "jd": "3.5"}
        result = sanitize_grade_item(item)
        assert result == item


class TestBuildFieldInventory:
    def test_basic_inventory(self):
        items = [
            {"kcmc": "课程A", "xf": "3.0", "cj": "85"},
            {"kcmc": "课程B", "xf": "2.0", "cj": None},
            {"kcmc": "课程C", "xf": "4.0", "cj": "90"},
        ]
        inv = build_field_inventory(items)

        assert "kcmc" in inv
        assert inv["kcmc"]["count"] == 3
        assert inv["kcmc"]["non_null_count"] == 3

        assert "cj" in inv
        assert inv["cj"]["count"] == 3
        assert inv["cj"]["non_null_count"] == 2  # one is None

    def test_handles_null_empty_array(self):
        items = [
            {"kcmc": "", "tags": []},
            {"kcmc": "课程", "tags": ["a"]},
        ]
        inv = build_field_inventory(items)
        # Empty string and empty list are considered "null"
        assert inv["kcmc"]["non_null_count"] == 1
        assert inv["tags"]["non_null_count"] == 1

    def test_types_tracked(self):
        items = [
            {"score": 85},
            {"score": "90"},
        ]
        inv = build_field_inventory(items)
        assert "int" in inv["score"]["types"]
        assert "str" in inv["score"]["types"]

    def test_student_id_sanitized_in_samples(self):
        items = [{"xh": "2023123456", "kcmc": "测试"}]
        inv = build_field_inventory(items)
        samples = inv["xh"]["samples"]
        assert any("****" in s for s in samples)
        assert "2023123456" not in samples


class TestSanitizeJsonForOutput:
    def test_nested_dict(self):
        data = {"user": {"xh": "2023123456", "name": "张三"}}
        result = sanitize_json_for_output(data)
        assert result["user"]["xh"] == "******3456"

    def test_list_of_items(self):
        data = [{"xh": "1234567890"}, {"xh": "0987654321"}]
        result = sanitize_json_for_output(data)
        assert "******7890" in str(result)
        assert "1234567890" not in str(result)

    def test_cookie_string_detected(self):
        data = {"headers": {"Cookie": "JSESSIONID=abc123"}}
        result = sanitize_json_for_output(data)
        assert "abc123" not in str(result)

    def test_non_personal_data_preserved(self):
        data = {"course": "数学", "score": 95}
        result = sanitize_json_for_output(data)
        assert result == data
