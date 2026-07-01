"""
Desensitization utilities for edu grade probe output.

Rules:
- Student ID: keep only last 4 digits (e.g. ******0128)
- Cookie values: completely remove, keep only cookie names
- Password: never print, never write
- Names: replace with "***"
- Teacher names: keep locally in output/, do not commit
- Course names: keep for identification purposes
- Original field names: never modify
- Token/CSRF: completely remove
"""

import re
import json
from typing import Any, Dict, List, Optional


def sanitize_student_id(sid: str) -> str:
    """Keep only last 4 digits of student ID."""
    if not sid or not isinstance(sid, str):
        return "****"
    if len(sid) <= 4:
        return "****"
    return "*" * (len(sid) - 4) + sid[-4:]


def sanitize_name(name: str) -> str:
    """Replace personal names with ***."""
    if not name or not isinstance(name, str):
        return "***"
    return "***"


def sanitize_cookie(cookie_str: Optional[str]) -> Optional[str]:
    """Remove cookie values, keep only cookie names."""
    if not cookie_str:
        return None
    # Extract cookie names only
    parts = cookie_str.split(";")
    names = []
    for part in parts:
        part = part.strip()
        if "=" in part:
            names.append(part.split("=")[0])
        elif part:
            names.append(part)
    return "; ".join(names) + "=<redacted>" if names else "<redacted>"


def sanitize_headers(headers: Dict[str, str]) -> Dict[str, str]:
    """Remove sensitive headers (Cookie, Authorization, CSRF tokens)."""
    sensitive = {"cookie", "set-cookie", "authorization", "x-csrftoken",
                 "csrf-token", "x-xsrf-token"}
    result = {}
    for k, v in headers.items():
        if k.lower() in sensitive:
            result[k] = "<redacted>"
        else:
            result[k] = v
    return result


def sanitize_grade_item(item: Dict[str, Any]) -> Dict[str, Any]:
    """Sanitize a single grade item dict."""
    sanitized = {}
    personal_fields = {
        "xm",      # 姓名
        "xsxm",    # 学生姓名
        "xh",      # 学号
        "xsxh",    # 学生学号
        "xsid",    # 学生ID
        "user_id",
        "sfzh",    # 身份证号
    }
    teacher_fields = {
        "jsxm",    # 教师姓名
        "jsmc",    # 教师名称
        "xm_jg",   # 教师姓名（教务）
    }
    id_fields = {
        "jxb_id",  # 教学班ID (keep as-is for matching, but not personal)
    }

    for key, value in item.items():
        if key.lower() in {f.lower() for f in personal_fields}:
            if isinstance(value, str) and value:
                sanitized[key] = sanitize_student_id(value) if key.lower() in {"xh", "xsxh", "xsid"} else sanitize_name(value)
            else:
                sanitized[key] = "***"
        elif key.lower() in {f.lower() for f in teacher_fields}:
            # Keep teacher names locally but mark them
            sanitized[key] = value  # will be excluded from git by output/ gitignore
        else:
            sanitized[key] = value

    return sanitized


def build_field_inventory(items: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Build a field inventory from a list of grade item dicts.
    Returns: dict with field_name -> {type, count, non_null_count, samples}
    """
    inventory: Dict[str, Dict[str, Any]] = {}

    for item in items:
        for key, value in item.items():
            if key not in inventory:
                inventory[key] = {
                    "count": 0,
                    "non_null_count": 0,
                    "types": set(),
                    "samples": [],
                }
            entry = inventory[key]
            entry["count"] += 1

            if value is not None and value != "" and value != []:
                entry["non_null_count"] += 1
                if len(entry["samples"]) < 3:
                    # Sanitize personal data in samples
                    sample = value
                    if key.lower() in {"xh", "xsxh", "xsid"} and isinstance(sample, str):
                        sample = sanitize_student_id(sample)
                    elif key.lower() in {"xm", "xsxm"} and isinstance(sample, str):
                        sample = sanitize_name(sample)
                    entry["samples"].append(sample)

            # Track types
            t = type(value).__name__
            entry["types"].add(t)

    # Convert sets to lists for JSON serialization
    for entry in inventory.values():
        entry["types"] = sorted(entry["types"])

    return inventory


def sanitize_json_for_output(data: Any) -> Any:
    """Recursively sanitize JSON-like data for safe output."""
    if isinstance(data, dict):
        return {k: sanitize_json_for_output(v) for k, v in data.items()}
    elif isinstance(data, list):
        return [sanitize_json_for_output(item) for item in data]
    elif isinstance(data, str):
        # Check if the string looks like a student ID (digits only, 8-12 chars)
        if re.match(r'^\d{8,12}$', data):
            return sanitize_student_id(data)
        # Check if it looks like a cookie
        if "JSESSIONID" in data or "route=" in data.lower():
            return sanitize_cookie(data)
        return data
    return data
