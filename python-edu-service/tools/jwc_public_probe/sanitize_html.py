"""
HTML 白名单清洗 — 兼容重导出入口

正式实现位于 services/html_sanitizer.py。
本文件保留以确保探针脚本和已有测试继续工作。
"""

from services.html_sanitizer import (  # noqa: F401
    sanitize_html,
    resolve_url,
    _is_unsafe_url,
    ALLOWED_TAGS,
)

__all__ = ["sanitize_html", "resolve_url", "_is_unsafe_url", "ALLOWED_TAGS"]
