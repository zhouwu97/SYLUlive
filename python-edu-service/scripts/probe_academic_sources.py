#!/usr/bin/env python3
"""阶段 3A.2 教务学业与毕业数据源脱敏探针。"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit

from bs4 import BeautifulSoup
import httpx

PROJECT_DIR = Path(__file__).resolve().parent.parent
if str(PROJECT_DIR) not in sys.path:
    sys.path.insert(0, str(PROJECT_DIR))

# 脚本支持从仓库根目录直接执行，因此项目路径必须先加入模块搜索路径。
from services.crawler import EduCrawler, LoginFailedError, NetworkError  # noqa: E402


PROBE_VERSION = "academic-source-probe-v2"
BASE_ORIGIN = "https://jxw.sylu.edu.cn"
MENU_URL = f"{BASE_ORIGIN}/xtgl/index_initMenu.html"
ACADEMIC_URL = f"{BASE_ORIGIN}/xsxy/xsxyqk_cxXsxyqkIndex.html"
DEFAULT_OUTPUT_DIR = PROJECT_DIR / "private-probe-output"

MENU_KEYWORDS = (
    "毕业审核",
    "毕业预警",
    "培养方案",
    "培养计划",
    "执行计划",
    "学业完成",
    "学分完成",
    "学分统计",
    "计划完成度",
    "学籍预警",
    "毕业",
)
SCRIPT_MARKERS = (
    "$.ajax",
    "fetch(",
    ".DataTable(",
    ".dataTable(",
    ".load(",
)
SCRIPT_LITERAL_URL_PATTERNS = (
    r"fetch\s*\(\s*['\"]([^'\"]+)['\"]",
    r"\.load\s*\(\s*['\"]([^'\"]+)['\"]",
    r"(?:url|ajax)\s*:\s*['\"]([^'\"]+)['\"]",
)
SCRIPT_EXPRESSION_URL_PATTERNS = (
    r"fetch\s*\(\s*(?!['\"])[^\s)]",
    r"\.load\s*\(\s*(?!['\"])[^\s)]",
    r"(?:url|ajax)\s*:\s*(?!['\"])[A-Za-z_$]",
)
SAFE_READ_TOKENS = ("cx", "query", "list", "index", "view", "get")
MUTATION_TOKENS = (
    "save",
    "delete",
    "remove",
    "update",
    "submit",
    "insert",
    "create",
    "edit",
    "upload",
    "download",
    "export",
    "保存",
    "删除",
    "提交",
)

FIELD_PATTERNS = {
    "contains_plan_id": (
        "培养方案编号",
        "方案编号",
        "pyfa_id",
        "pyfah",
        "plan_id",
        "planid",
    ),
    "contains_module_groups": (
        "培养模块",
        "课程模块",
        "模块名称",
        "课程类别",
        "module_name",
        "modulegroup",
    ),
    "contains_required_credits": (
        "要求学分",
        "应修学分",
        "毕业要求学分",
        "required_credits",
        "requirecredit",
    ),
    "contains_earned_credits": (
        "已获得学分",
        "已获学分",
        "已修学分",
        "earned_credits",
        "acquiredcredit",
    ),
    "contains_remaining_credits": (
        "剩余学分",
        "学分缺口",
        "差额学分",
        "remaining_credits",
        "creditgap",
    ),
    "contains_official_update_time": (
        "更新时间",
        "更新日期",
        "数据时间",
        "updated_at",
        "update_time",
    ),
}
COURSE_FIELD_TOKENS = (
    "课程名称",
    "课程代码",
    "课程号",
    "kcmc",
    "kch",
    "course_name",
    "coursecode",
)
ACADEMIC_SUMMARY_TOKENS = (
    "平均学分绩点",
    "计划总课程",
    "计划学位课程",
    "all_gpa",
    "degree_gpa",
    "total_courses",
)
COMMON_STRUCTURE_KEYS = (
    "data",
    "items",
    "rows",
    "list",
    "result",
    "records",
    "page",
    "total",
    "code",
    "status",
    "message",
    "success",
)
SAFE_TABLE_HEADERS = (
    "序号",
    "课程名称",
    "课程代码",
    "课程号",
    "课程类别",
    "课程性质",
    "课程模块",
    "模块名称",
    "修读状态",
    "学分",
    "成绩",
    "最大成绩",
    "绩点",
    "学年",
    "学期",
    "学年学期",
    "培养方案编号",
    "方案编号",
    "要求学分",
    "应修学分",
    "毕业要求学分",
    "已获得学分",
    "已获学分",
    "已修学分",
    "剩余学分",
    "学分缺口",
    "差额学分",
    "更新时间",
    "更新日期",
    "数据时间",
)


@dataclass
class RequestCandidate:
    name: str
    url: str = field(repr=False)
    method: str = "GET"
    parameter_names: tuple[str, ...] = ()
    form_data: dict[str, str] = field(default_factory=dict, repr=False)
    discovered_from: tuple[str, ...] = ()
    kind: str = "dynamic"
    gnmkdm: str | None = None

    @property
    def source_url(self) -> str:
        return urlsplit(self.url).path


def _normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def _is_structural_json_key(value: str) -> bool:
    tokens = (
        *COMMON_STRUCTURE_KEYS,
        *COURSE_FIELD_TOKENS,
        *ACADEMIC_SUMMARY_TOKENS,
        *(token for patterns in FIELD_PATTERNS.values() for token in patterns),
    )
    if len(value) > 120:
        return False
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", value):
        return value in tokens
    lowered = value.lower()
    return any(token.lower() in lowered for token in tokens)


def _safe_table_header(value: str) -> str | None:
    text = _normalize_text(value).rstrip(":：")
    return text if text in SAFE_TABLE_HEADERS else None


def _safe_alias(value: str | None, option: str, *, required: bool = True) -> str | None:
    if value is None and not required:
        return None
    text = (value or "").strip()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,31}", text):
        raise ValueError(f"{option} 必须是以字母开头的 1-32 位匿名标签")
    return text


def _same_origin_url(raw_url: str, base_url: str) -> str | None:
    value = (raw_url or "").strip().strip("'\"")
    if not value or value.startswith(("javascript:", "#", "data:")):
        return None
    absolute = urljoin(base_url, value)
    parsed = urlsplit(absolute)
    if parsed.scheme != "https" or parsed.netloc.lower() != "jxw.sylu.edu.cn":
        return None
    return absolute


def _source_path(raw_url: str, base_url: str) -> str | None:
    safe = _same_origin_url(raw_url, base_url)
    return urlsplit(safe).path if safe else None


def _parameter_names(url: str, extra: Iterable[str] = ()) -> tuple[str, ...]:
    names = set(parse_qs(urlsplit(url).query, keep_blank_values=True))
    names.update(
        name for name in extra if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", name)
    )
    return tuple(sorted(names))


def _gnmkdm(url: str, raw_text: str = "") -> str | None:
    values = parse_qs(urlsplit(url).query).get("gnmkdm", [])
    if values and re.fullmatch(r"N\d{4,8}", values[0]):
        return values[0]
    match = re.search(r"\bN\d{4,8}\b", raw_text)
    return match.group(0) if match else None


def _candidate_key(candidate: RequestCandidate) -> tuple[str, str]:
    return candidate.method.upper(), candidate.url


def _deduplicate_candidates(
    candidates: Iterable[RequestCandidate],
) -> list[RequestCandidate]:
    merged: dict[tuple[str, str], RequestCandidate] = {}
    for candidate in candidates:
        key = _candidate_key(candidate)
        current = merged.get(key)
        if current is None:
            merged[key] = candidate
            continue
        current.parameter_names = tuple(
            sorted(set(current.parameter_names) | set(candidate.parameter_names))
        )
        current.discovered_from = tuple(
            sorted(set(current.discovered_from) | set(candidate.discovered_from))
        )
        for name, value in candidate.form_data.items():
            current.form_data.setdefault(name, value)
        if current.kind != "menu" and candidate.kind == "menu":
            current.kind = "menu"
            current.name = candidate.name
        current.gnmkdm = current.gnmkdm or candidate.gnmkdm
    return sorted(
        merged.values(), key=lambda item: (item.kind, item.source_url, item.method)
    )


def _script_method(script: str, start: int) -> str:
    window = script[max(0, start - 240) : start + 360]
    match = re.search(
        r"(?:type|method)\s*:\s*['\"](GET|POST)['\"]",
        window,
        flags=re.IGNORECASE,
    )
    return match.group(1).upper() if match else "GET"


def discover_script_candidates(
    script: str,
    base_url: str,
    *,
    source: str,
) -> list[RequestCandidate]:
    data_blocks = re.findall(r"data\s*:\s*\{([^{}]{0,1000})\}", script)
    parameter_names = tuple(
        sorted(
            set(
                re.findall(
                    r"\b([A-Za-z_][A-Za-z0-9_.-]*)\s*:",
                    " ".join(data_blocks),
                )
            )
        )
    )
    static_values = {
        key: value
        for block in data_blocks
        for key, value in re.findall(
            r"\b([A-Za-z_][A-Za-z0-9_.-]*)\s*:\s*['\"]([^'\"]{0,200})['\"]",
            block,
        )
    }
    candidates: list[RequestCandidate] = []
    for pattern in SCRIPT_LITERAL_URL_PATTERNS:
        for match in re.finditer(pattern, script, flags=re.IGNORECASE):
            url = _same_origin_url(match.group(1), base_url)
            if not url:
                continue
            method = (
                "GET"
                if ".load" in match.group(0)
                else _script_method(script, match.start())
            )
            candidates.append(
                RequestCandidate(
                    name=f"脚本候选 {urlsplit(url).path}",
                    url=url,
                    method=method,
                    parameter_names=_parameter_names(url, parameter_names),
                    form_data=dict(static_values),
                    discovered_from=(source,),
                    gnmkdm=_gnmkdm(url, match.group(0)),
                )
            )
    return _deduplicate_candidates(candidates)


def _unresolved_dynamic_reference_count(script: str) -> int:
    expression_count = sum(
        len(re.findall(pattern, script, flags=re.IGNORECASE))
        for pattern in SCRIPT_EXPRESSION_URL_PATTERNS
    )
    unresolved_calls = 0
    for pattern in (r"fetch\s*\(", r"\.load\s*\("):
        for match in re.finditer(pattern, script, flags=re.IGNORECASE):
            argument = script[match.end() : match.end() + 200].lstrip()
            if not argument.startswith(("'", '"')):
                unresolved_calls += 1

    for pattern in (r"\$\s*\.ajax\s*\(", r"\.datatable\s*\("):
        for match in re.finditer(pattern, script, flags=re.IGNORECASE):
            window = script[match.end() : match.end() + 1200]
            property_match = re.search(
                r"(?:url|ajax)\s*:\s*([^,}\r\n]+)",
                window,
                flags=re.IGNORECASE,
            )
            if not property_match or not property_match.group(1).lstrip().startswith(
                ("'", '"')
            ):
                unresolved_calls += 1
    return max(expression_count, unresolved_calls)


def _form_candidate(form: Any, base_url: str) -> RequestCandidate | None:
    action = _same_origin_url(str(form.get("action") or ""), base_url)
    if not action:
        return None
    method = str(form.get("method") or "GET").upper()
    method = method if method in {"GET", "POST"} else "GET"
    form_data: dict[str, str] = {}
    field_names: list[str] = []
    for control in form.select("input[name], select[name], textarea[name]"):
        name = str(control.get("name") or "").strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", name):
            continue
        field_names.append(name)
        if (
            control.name == "input"
            and str(control.get("type") or "").lower() == "hidden"
        ):
            form_data[name] = str(control.get("value") or "")
    return RequestCandidate(
        name=f"表单 {urlsplit(action).path}",
        url=action,
        method=method,
        parameter_names=_parameter_names(action, field_names),
        form_data=form_data,
        discovered_from=("form",),
        gnmkdm=_gnmkdm(action),
    )


def _course_table_shape(soup: BeautifulSoup) -> tuple[bool, int]:
    for table in soup.select("table"):
        rows = table.select("tr")
        for index, row in enumerate(rows):
            headers = {
                _normalize_text(cell.get_text(" ", strip=True))
                for cell in row.select("th,td")
            }
            if {"课程名称", "最大成绩", "修读状态"}.issubset(headers):
                data_rows = sum(
                    1
                    for item in rows[index + 1 :]
                    if _normalize_text(item.get_text(" ", strip=True))
                )
                return True, data_rows
    return False, 0


def analyze_html_structure(
    html: str, base_url: str
) -> tuple[dict[str, Any], list[RequestCandidate]]:
    soup = BeautifulSoup(html or "", "html.parser")
    candidates: list[RequestCandidate] = []
    forms: list[dict[str, Any]] = []
    all_field_names: set[str] = set()
    hidden_values: dict[str, str] = {}

    for control in soup.select("input[type=hidden]"):
        value = str(control.get("value") or "")
        for attribute in ("name", "id"):
            name = str(control.get(attribute) or "").strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", name):
                hidden_values[name] = value

    for form in soup.select("form"):
        candidate = _form_candidate(form, base_url)
        field_names = sorted(
            {
                str(control.get("name"))
                for control in form.select("input[name], select[name], textarea[name]")
                if re.fullmatch(
                    r"[A-Za-z_][A-Za-z0-9_.-]*",
                    str(control.get("name") or ""),
                )
            }
        )
        all_field_names.update(field_names)
        forms.append(
            {
                "action": candidate.source_url if candidate else None,
                "method": candidate.method
                if candidate
                else str(form.get("method") or "GET").upper(),
                "field_names": field_names,
            }
        )
        if candidate:
            candidates.append(candidate)

    script_sources = sorted(
        {
            path
            for script in soup.select("script[src]")
            if (path := _source_path(str(script.get("src") or ""), base_url))
        }
    )
    iframe_sources: set[str] = set()
    data_sources: set[str] = set()

    for iframe in soup.select("iframe[src]"):
        raw = str(iframe.get("src") or "")
        url = _same_origin_url(raw, base_url)
        if url:
            iframe_sources.add(urlsplit(url).path)
            candidates.append(
                RequestCandidate(
                    name=f"iframe {urlsplit(url).path}",
                    url=url,
                    parameter_names=_parameter_names(url),
                    discovered_from=("iframe",),
                    gnmkdm=_gnmkdm(url),
                )
            )

    for element in soup.select("[data-url], [data-ajax], [data-source]"):
        for attribute in ("data-url", "data-ajax", "data-source"):
            raw = str(element.get(attribute) or "")
            url = _same_origin_url(raw, base_url)
            if not url:
                continue
            data_sources.add(urlsplit(url).path)
            candidates.append(
                RequestCandidate(
                    name=f"{attribute} {urlsplit(url).path}",
                    url=url,
                    parameter_names=_parameter_names(url),
                    discovered_from=(attribute,),
                    gnmkdm=_gnmkdm(url),
                )
            )

    inline_scripts = [
        script.get_text(" ", strip=False) for script in soup.select("script:not([src])")
    ]
    for script in inline_scripts:
        candidates.extend(
            discover_script_candidates(script, base_url, source="inline_script")
        )

    for candidate in candidates:
        for name in candidate.parameter_names:
            if name in hidden_values and name not in candidate.form_data:
                candidate.form_data[name] = hidden_values[name]

    raw_table_headers = {
        _normalize_text(cell.get_text(" ", strip=True))
        for cell in soup.select("table th")
        if _normalize_text(cell.get_text(" ", strip=True))
    }
    table_headers = sorted(
        header
        for raw_header in raw_table_headers
        if (header := _safe_table_header(raw_header)) is not None
    )
    redacted_table_header_count = len(raw_table_headers) - len(table_headers)
    course_table_present, course_data_rows = _course_table_shape(soup)
    marker_counts = {
        marker: sum(script.count(marker) for script in inline_scripts)
        for marker in SCRIPT_MARKERS
    }
    unresolved_dynamic_reference_count = sum(
        _unresolved_dynamic_reference_count(script) for script in inline_scripts
    )
    signature_payload = {
        "forms": forms,
        "table_headers": table_headers,
        "redacted_table_header_count": redacted_table_header_count,
        "script_sources": script_sources,
        "iframes": sorted(iframe_sources),
        "data_sources": sorted(data_sources),
        "markers": marker_counts,
        "unresolved_dynamic_reference_count": unresolved_dynamic_reference_count,
    }
    structure_signature = hashlib.sha256(
        json.dumps(signature_payload, ensure_ascii=True, sort_keys=True).encode("utf-8")
    ).hexdigest()

    summary = {
        "forms": forms,
        "form_count": len(forms),
        "table_count": len(soup.select("table")),
        "iframe_sources": sorted(iframe_sources),
        "script_sources": script_sources,
        "data_sources": sorted(data_sources),
        "field_names": sorted(all_field_names),
        "table_headers": table_headers,
        "redacted_table_header_count": redacted_table_header_count,
        "inline_script_count": len(inline_scripts),
        "script_marker_counts": marker_counts,
        "unresolved_dynamic_reference_count": unresolved_dynamic_reference_count,
        "gnmkdm_values": sorted(
            {
                value
                for candidate in candidates
                if (value := candidate.gnmkdm) is not None
            }
        ),
        "course_table_present": course_table_present,
        "course_data_row_count": course_data_rows,
        "structure_signature": structure_signature,
    }
    return summary, _deduplicate_candidates(candidates)


def discover_menu_candidates(
    html: str, base_url: str
) -> tuple[list[RequestCandidate], list[dict[str, Any]]]:
    soup = BeautifulSoup(html or "", "html.parser")
    candidates: list[RequestCandidate] = []
    without_url: list[dict[str, Any]] = []
    for element in soup.select(
        "a, button, [data-url], [data-ajax], [data-source], [onclick]"
    ):
        text = _normalize_text(element.get_text(" ", strip=True))
        if not text or not any(keyword in text for keyword in MENU_KEYWORDS):
            continue
        name = next(keyword for keyword in MENU_KEYWORDS if keyword in text)
        raw_values = [
            str(element.get(attribute) or "")
            for attribute in ("href", "data-url", "data-ajax", "data-source")
        ]
        onclick = str(element.get("onclick") or "")
        raw_values.extend(
            re.findall(r"['\"]([^'\"]+(?:\.html|gnmkdm=)[^'\"]*)['\"]", onclick)
        )
        found = False
        for raw in raw_values:
            url = _same_origin_url(raw, base_url)
            if not url:
                continue
            found = True
            candidates.append(
                RequestCandidate(
                    name=name,
                    url=url,
                    method="GET",
                    parameter_names=_parameter_names(url),
                    discovered_from=("menu",),
                    kind="menu",
                    gnmkdm=_gnmkdm(url, onclick),
                )
            )
        if not found:
            without_url.append(
                {
                    "name": name,
                    "gnmkdm": _gnmkdm("", onclick),
                    "source_url": None,
                    "verification_status": "no_url_discovered",
                }
            )
    candidates = _deduplicate_candidates(candidates)
    names_with_url = {candidate.name for candidate in candidates}
    without_url = [item for item in without_url if item["name"] not in names_with_url]
    return candidates, without_url


def _json_shape(value: Any, *, depth: int = 0) -> dict[str, Any]:
    if depth >= 3:
        return {"type": type(value).__name__}
    if isinstance(value, dict):
        raw_keys = [str(key) for key in value]
        keys = sorted(key for key in raw_keys if _is_structural_json_key(key))[:200]
        redacted_keys = [key for key in raw_keys if not _is_structural_json_key(key)]
        return {
            "type": "object",
            "keys": keys,
            "redacted_key_count": len(redacted_keys),
            "children": {
                key: _json_shape(value[key], depth=depth + 1)
                for key in keys[:30]
                if key in value
            },
            "redacted_children": [
                _json_shape(value[key], depth=depth + 1) for key in redacted_keys[:10]
            ],
        }
    if isinstance(value, list):
        return {
            "type": "array",
            "length": len(value),
            "item": _json_shape(value[0], depth=depth + 1) if value else None,
        }
    return {"type": type(value).__name__}


def _shape_contract(shape: Mapping[str, Any]) -> dict[str, Any]:
    contract: dict[str, Any] = {"type": shape.get("type")}
    if "keys" in shape:
        contract["keys"] = list(shape.get("keys", []))
        contract["redacted_key_count"] = int(shape.get("redacted_key_count", 0))
    children = shape.get("children") or {}
    if children:
        contract["children"] = {
            str(key): _shape_contract(value)
            for key, value in children.items()
            if isinstance(value, Mapping)
        }
    item = shape.get("item")
    if isinstance(item, Mapping):
        contract["item"] = _shape_contract(item)
    redacted_children = shape.get("redacted_children") or []
    if redacted_children:
        contract["redacted_children"] = [
            _shape_contract(child)
            for child in redacted_children
            if isinstance(child, Mapping)
        ]
    return contract


def _shape_field_names(shape: Mapping[str, Any]) -> set[str]:
    names = {str(key) for key in shape.get("keys", [])}
    for child in (shape.get("children") or {}).values():
        if isinstance(child, Mapping):
            names.update(_shape_field_names(child))
    item = shape.get("item")
    if isinstance(item, Mapping):
        names.update(_shape_field_names(item))
    for child in shape.get("redacted_children") or []:
        if isinstance(child, Mapping):
            names.update(_shape_field_names(child))
    return names


def _contains_pattern(search_text: str, patterns: Sequence[str]) -> bool:
    lowered = search_text.lower()
    return any(pattern.lower() in lowered for pattern in patterns)


def _is_non_empty_business_value(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip().lower() not in {
            "",
            "-",
            "--",
            "null",
            "none",
            "暂无",
            "无",
        }
    if isinstance(value, Mapping):
        return any(_is_non_empty_business_value(item) for item in value.values())
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return any(_is_non_empty_business_value(item) for item in value)
    return True


def _json_has_non_empty_field(value: Any, patterns: Sequence[str]) -> bool:
    if isinstance(value, Mapping):
        for key, item in value.items():
            if _contains_pattern(str(key), patterns) and _is_non_empty_business_value(
                item
            ):
                return True
        return any(_json_has_non_empty_field(item, patterns) for item in value.values())
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return any(_json_has_non_empty_field(item, patterns) for item in value)
    return False


def _json_has_non_empty_module_record(value: Any) -> bool:
    module_patterns = (
        *FIELD_PATTERNS["contains_module_groups"],
        "modules",
        "module_list",
    )
    return _json_has_non_empty_field(value, module_patterns)


def _html_has_non_empty_credit(soup: BeautifulSoup, patterns: Sequence[str]) -> bool:
    for table in soup.select("table"):
        rows = table.select("tr")
        for index, row in enumerate(rows):
            cells = row.select("th,td")
            matching_columns = [
                column
                for column, cell in enumerate(cells)
                if _contains_pattern(
                    _normalize_text(cell.get_text(" ", strip=True)), patterns
                )
            ]
            if not matching_columns:
                continue
            for data_row in rows[index + 1 :]:
                values = data_row.select("th,td")
                if any(
                    column < len(values)
                    and re.fullmatch(
                        r"[-+]?\d+(?:\.\d+)?",
                        _normalize_text(values[column].get_text(" ", strip=True)),
                    )
                    for column in matching_columns
                ):
                    return True
    text = _normalize_text(soup.get_text(" ", strip=True))
    return any(
        re.search(
            rf"{re.escape(pattern)}[^0-9]{{0,24}}[-+]?\d+(?:\.\d+)?",
            text,
            flags=re.IGNORECASE,
        )
        is not None
        for pattern in patterns
    )


def _html_has_non_empty_module_record(soup: BeautifulSoup) -> bool:
    patterns = FIELD_PATTERNS["contains_module_groups"]
    for table in soup.select("table"):
        rows = table.select("tr")
        for index, row in enumerate(rows):
            header = _normalize_text(row.get_text(" ", strip=True))
            if not _contains_pattern(header, patterns):
                continue
            if any(
                _normalize_text(item.get_text(" ", strip=True)).lower()
                not in {"", "-", "--", "暂无", "无数据"}
                for item in rows[index + 1 :]
            ):
                return True
    return False


def summarize_response(
    *,
    name: str,
    source_url: str,
    method: str,
    parameter_names: Sequence[str],
    response: httpx.Response,
    authentication: str = "authenticated_session",
) -> dict[str, Any]:
    content_type = (
        response.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    )
    body = response.text or ""
    login_redirect = response.status_code in (302, 901) or "login_slogin" in body
    parsed_json: Any = None
    if "json" in content_type or body.lstrip().startswith(("{", "[")):
        try:
            parsed_json = json.loads(body)
        except json.JSONDecodeError:
            parsed_json = None

    if parsed_json is not None:
        response_shape = _json_shape(parsed_json)
        field_names = _shape_field_names(response_shape)
        search_text = " ".join(sorted(field_names))
        course_details = _json_has_course_records(parsed_json)
        non_empty_evidence = {
            "has_non_empty_required_credits": _json_has_non_empty_field(
                parsed_json, FIELD_PATTERNS["contains_required_credits"]
            ),
            "has_non_empty_earned_credits": _json_has_non_empty_field(
                parsed_json, FIELD_PATTERNS["contains_earned_credits"]
            ),
            "has_non_empty_remaining_credits": _json_has_non_empty_field(
                parsed_json, FIELD_PATTERNS["contains_remaining_credits"]
            ),
            "has_non_empty_module_record": _json_has_non_empty_module_record(
                parsed_json
            ),
            "has_non_empty_course_record": course_details,
        }
        academic_summary = _contains_pattern(search_text, ACADEMIC_SUMMARY_TOKENS)
        structure_signature = hashlib.sha256(
            json.dumps(
                _shape_contract(response_shape),
                ensure_ascii=True,
                sort_keys=True,
            ).encode("utf-8")
        ).hexdigest()
    else:
        html_summary, _ = analyze_html_structure(body, urljoin(BASE_ORIGIN, source_url))
        soup = BeautifulSoup(body, "html.parser")
        visible_text = _normalize_text(soup.get_text(" ", strip=True))
        structural_text = " ".join(
            html_summary["field_names"] + html_summary["table_headers"] + [visible_text]
        )
        response_shape = {
            "type": "html",
            "forms": html_summary["form_count"],
            "tables": html_summary["table_count"],
            "iframes": len(html_summary["iframe_sources"]),
            "field_names": html_summary["field_names"],
            "table_headers": html_summary["table_headers"],
            "redacted_table_header_count": html_summary["redacted_table_header_count"],
        }
        search_text = structural_text
        course_details = _html_has_course_records(soup)
        non_empty_evidence = {
            "has_non_empty_required_credits": _html_has_non_empty_credit(
                soup, FIELD_PATTERNS["contains_required_credits"]
            ),
            "has_non_empty_earned_credits": _html_has_non_empty_credit(
                soup, FIELD_PATTERNS["contains_earned_credits"]
            ),
            "has_non_empty_remaining_credits": _html_has_non_empty_credit(
                soup, FIELD_PATTERNS["contains_remaining_credits"]
            ),
            "has_non_empty_module_record": _html_has_non_empty_module_record(soup),
            "has_non_empty_course_record": course_details,
        }
        academic_summary = _contains_pattern(search_text, ACADEMIC_SUMMARY_TOKENS)
        structure_signature = html_summary["structure_signature"]

    flags = {
        key: _contains_pattern(search_text, patterns)
        for key, patterns in FIELD_PATTERNS.items()
    }
    flags["contains_course_details"] = course_details
    flags["contains_academic_summary"] = academic_summary
    has_business_data = (
        academic_summary
        or course_details
        or any(
            flags[key]
            for key in (
                "contains_plan_id",
                "contains_module_groups",
                "contains_required_credits",
                "contains_earned_credits",
                "contains_remaining_credits",
            )
        )
    )
    stable_for_current_account = (
        response.status_code == 200 and not login_redirect and has_business_data
    )
    if login_redirect:
        verification_status = "authentication_failed"
    elif response.status_code != 200:
        verification_status = "request_failed_status"
    elif stable_for_current_account:
        verification_status = "verified_business_response"
    else:
        verification_status = "responded_without_verified_business_fields"

    return {
        "name": name,
        "source_url": source_url,
        "method": method,
        "status_code": response.status_code,
        "content_type": content_type or "unknown",
        "authentication": authentication,
        "required_parameters": sorted(set(parameter_names)),
        "response_shape": response_shape,
        "structure_signature": structure_signature,
        **flags,
        **non_empty_evidence,
        "stable_for_current_account": stable_for_current_account,
        "verification_status": verification_status,
    }


def _json_has_course_records(value: Any) -> bool:
    if isinstance(value, dict):
        course_keys = [
            str(key)
            for key in value
            if _contains_pattern(str(key), COURSE_FIELD_TOKENS)
        ]
        if any(value.get(key) not in (None, "", []) for key in course_keys):
            return True
        return any(_json_has_course_records(item) for item in value.values())
    if isinstance(value, list):
        return any(_json_has_course_records(item) for item in value)
    return False


def _html_has_course_records(soup: BeautifulSoup) -> bool:
    for table in soup.select("table"):
        rows = table.select("tr")
        for index, row in enumerate(rows):
            headers = " ".join(
                _normalize_text(cell.get_text(" ", strip=True))
                for cell in row.select("th,td")
            )
            if not _contains_pattern(headers, COURSE_FIELD_TOKENS):
                continue
            return any(
                _normalize_text(item.get_text(" ", strip=True))
                for item in rows[index + 1 :]
            )
    return False


def _is_safe_read_candidate(candidate: RequestCandidate) -> bool:
    path = candidate.source_url.lower()
    if candidate.method not in {"GET", "POST"}:
        return False
    if any(token in path for token in MUTATION_TOKENS):
        return False
    return any(token in path for token in SAFE_READ_TOKENS)


def _allowed_post_path(value: str) -> str:
    parsed = urlsplit((value or "").strip())
    path = parsed.path
    if (
        not path.startswith("/")
        or parsed.scheme
        or parsed.netloc
        or parsed.query
        or parsed.fragment
        or any(token in path.lower() for token in MUTATION_TOKENS)
    ):
        raise ValueError(
            "--allow-post 必须是无查询参数、无写操作关键词的教务站内绝对路径"
        )
    return path


def _unresolved_parameter_names(candidate: RequestCandidate) -> list[str]:
    query = parse_qs(urlsplit(candidate.url).query, keep_blank_values=True)
    supplied = {
        key
        for key, values in query.items()
        if any(str(value).strip() for value in values)
    }
    supplied.update(
        key for key, value in candidate.form_data.items() if str(value).strip()
    )
    return sorted(set(candidate.parameter_names) - supplied)


class AcademicSourceProbe:
    def __init__(
        self,
        client: httpx.AsyncClient,
        cookie: str,
        *,
        allowed_post_paths: Iterable[str] = (),
    ):
        self.client = client
        self._cookie = cookie
        self._allowed_post_paths = frozenset(allowed_post_paths)

    async def _get(
        self, url: str, *, params: Mapping[str, str] | None = None
    ) -> httpx.Response:
        return await self.client.get(
            url,
            params=params,
            headers={
                "Cookie": self._cookie,
                "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
                "Referer": MENU_URL,
            },
        )

    async def _request_candidate(self, candidate: RequestCandidate) -> dict[str, Any]:
        unresolved_parameters = _unresolved_parameter_names(candidate)
        base = {
            "name": candidate.name,
            "source_url": candidate.source_url,
            "method": candidate.method,
            "authentication": "authenticated_session",
            "required_parameters": list(candidate.parameter_names),
            "gnmkdm": candidate.gnmkdm,
            "discovered_from": list(candidate.discovered_from),
            "kind": candidate.kind,
            "parameters_complete": not unresolved_parameters,
            "unresolved_parameters": unresolved_parameters,
        }
        path = candidate.source_url.lower()
        if candidate.method not in {"GET", "POST"} or any(
            token in path for token in MUTATION_TOKENS
        ):
            return {**base, "verification_status": "skipped_not_proven_read_only"}
        if candidate.method == "POST":
            if candidate.source_url not in self._allowed_post_paths:
                return {**base, "verification_status": "skipped_post_not_allowed"}
        elif not _is_safe_read_candidate(candidate):
            return {**base, "verification_status": "skipped_not_proven_read_only"}
        try:
            if candidate.method == "POST":
                response = await self.client.post(
                    candidate.url,
                    data=candidate.form_data,
                    headers={
                        "Cookie": self._cookie,
                        "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
                        "Referer": ACADEMIC_URL,
                    },
                )
            else:
                parsed = urlsplit(candidate.url)
                query = {
                    key: values[-1]
                    for key, values in parse_qs(
                        parsed.query, keep_blank_values=True
                    ).items()
                }
                query.update(candidate.form_data)
                request_url = urlunsplit(
                    (parsed.scheme, parsed.netloc, parsed.path, "", "")
                )
                response = await self._get(request_url, params=query or None)
        except httpx.HTTPError as exc:
            return {
                **base,
                "verification_status": "request_failed",
                "error_type": type(exc).__name__,
            }
        return {
            **base,
            **summarize_response(
                name=candidate.name,
                source_url=candidate.source_url,
                method=candidate.method,
                parameter_names=candidate.parameter_names,
                response=response,
            ),
        }

    async def run(self, sample: Mapping[str, str | None]) -> dict[str, Any]:
        menu_response = await self._get(MENU_URL)
        academic_response = await self._get(
            ACADEMIC_URL,
            params={"gnmkdm": "N105515", "layout": "default"},
        )
        if menu_response.status_code != 200 or "login_slogin" in menu_response.text:
            raise RuntimeError("教务首页会话无效，无法执行登录后菜单探测")
        if (
            academic_response.status_code != 200
            or "login_slogin" in academic_response.text
        ):
            raise RuntimeError("学业情况页面会话无效，无法执行结构探测")

        menu_structure, menu_page_candidates = analyze_html_structure(
            menu_response.text, str(menu_response.url)
        )
        academic_structure, academic_candidates = analyze_html_structure(
            academic_response.text, str(academic_response.url)
        )
        menu_candidates, menu_without_url = discover_menu_candidates(
            menu_response.text, str(menu_response.url)
        )

        external_script_candidates: list[RequestCandidate] = []
        external_scripts: list[dict[str, Any]] = []
        page_script_paths = sorted(
            set(academic_structure["script_sources"] + menu_structure["script_sources"])
        )
        for script_path in page_script_paths[:30]:
            script_url = _same_origin_url(script_path, BASE_ORIGIN)
            if not script_url:
                continue
            try:
                response = await self._get(script_url)
            except httpx.HTTPError as exc:
                external_scripts.append(
                    {
                        "source_url": script_path,
                        "verification_status": "request_failed",
                        "error_type": type(exc).__name__,
                    }
                )
                continue
            discovered = discover_script_candidates(
                response.text,
                str(response.url),
                source=f"external_script:{script_path}",
            )
            external_script_candidates.extend(discovered)
            unresolved_references = _unresolved_dynamic_reference_count(response.text)
            script_body = response.text.lstrip().lower()
            if "login_slogin" in response.text:
                script_verification_status = "authentication_failed"
            elif script_body.startswith(("<!doctype html", "<html")):
                script_verification_status = "unexpected_html_response"
            else:
                script_verification_status = "verified"
            external_scripts.append(
                {
                    "source_url": script_path,
                    "status_code": response.status_code,
                    "content_type": response.headers.get("content-type", "").split(
                        ";", 1
                    )[0],
                    "candidate_count": len(discovered),
                    "unresolved_dynamic_reference_count": unresolved_references,
                    "verification_status": script_verification_status,
                }
            )

        candidates = _deduplicate_candidates(
            [
                *menu_page_candidates,
                *academic_candidates,
                *menu_candidates,
                *external_script_candidates,
            ]
        )
        known_paths = {
            urlsplit(MENU_URL).path,
            urlsplit(ACADEMIC_URL).path,
        }
        candidates = [item for item in candidates if item.source_url not in known_paths]
        discovered_candidate_count = len(candidates)
        verified_requests = []
        for candidate in candidates[:40]:
            verified_requests.append(await self._request_candidate(candidate))

        academic_summary = summarize_response(
            name="官方学业情况",
            source_url=urlsplit(ACADEMIC_URL).path,
            method="GET",
            parameter_names=("gnmkdm", "layout"),
            response=academic_response,
        )
        verified_requests.insert(0, academic_summary)
        diagnosis = diagnose_courses_empty(academic_structure, verified_requests)
        verified_menu_candidates = [
            item for item in verified_requests if item.get("kind") == "menu"
        ] + menu_without_url
        unverified_candidates = [
            {
                "source_url": item.get("source_url"),
                "method": item.get("method"),
                "verification_status": item.get("verification_status"),
                "unresolved_parameters": item.get("unresolved_parameters", []),
            }
            for item in verified_requests
            if str(item.get("verification_status", "")).startswith("skipped_")
            or item.get("verification_status")
            in {"request_failed", "request_failed_status", "authentication_failed"}
            or item.get("parameters_complete") is False
        ]
        unresolved_dynamic_reference_count = (
            int(academic_structure.get("unresolved_dynamic_reference_count", 0))
            + int(menu_structure.get("unresolved_dynamic_reference_count", 0))
            + sum(
                int(item.get("unresolved_dynamic_reference_count", 0))
                for item in external_scripts
            )
        )
        probe_blockers = []
        if menu_without_url:
            probe_blockers.append("menu_candidate_without_url")
        if discovered_candidate_count > 40:
            probe_blockers.append("candidate_limit_reached")
        if len(page_script_paths) > 30:
            probe_blockers.append("external_script_limit_reached")
        if any(
            item.get("verification_status")
            in {"request_failed", "request_failed_status", "authentication_failed"}
            for item in verified_requests
        ):
            probe_blockers.append("candidate_request_failed")
        if any(item.get("parameters_complete") is False for item in verified_requests):
            probe_blockers.append("candidate_parameters_unresolved")
        if any(
            str(item.get("verification_status", "")).startswith("skipped_")
            for item in verified_requests
        ):
            probe_blockers.append("candidate_not_verified_read_only")
        if unresolved_dynamic_reference_count > 0:
            probe_blockers.append("dynamic_request_reference_unresolved")
        if any(
            item.get("verification_status") != "verified"
            or int(item.get("status_code", 0)) != 200
            for item in external_scripts
        ):
            probe_blockers.append("external_script_request_failed")

        return {
            "probe_version": PROBE_VERSION,
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "sample": dict(sample),
            "privacy": {
                "raw_html_saved": False,
                "response_values_saved": False,
                "cookies_saved": False,
                "credentials_saved": False,
                "personal_text_saved": False,
            },
            "probe_scope": {
                "academic_page": urlsplit(ACADEMIC_URL).path,
                "menu_page": urlsplit(MENU_URL).path,
                "same_origin_only": True,
                "candidate_limit": 40,
                "allowed_post_paths": sorted(self._allowed_post_paths),
            },
            "academic_page_structure": academic_structure,
            "menu_page_structure": menu_structure,
            "menu_candidates": verified_menu_candidates,
            "external_scripts": external_scripts,
            "candidate_inventory": {
                "discovered": discovered_candidate_count,
                "attempted": min(discovered_candidate_count, 40),
                "truncated": discovered_candidate_count > 40,
            },
            "verified_requests": verified_requests,
            "unverified_candidates": unverified_candidates,
            "unresolved_dynamic_reference_count": unresolved_dynamic_reference_count,
            "courses_empty_diagnosis": diagnosis,
            "probe_completeness": {
                "complete": not probe_blockers,
                "blockers": sorted(set(probe_blockers)),
            },
        }


def diagnose_courses_empty(
    academic_structure: Mapping[str, Any],
    verified_requests: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    if (
        academic_structure.get("course_table_present")
        and academic_structure.get("course_data_row_count", 0) > 0
    ):
        return {
            "result": "courses_in_initial_html",
            "initial_html_has_course_rows": True,
            "verified_dynamic_source": None,
        }
    verified_dynamic = next(
        (
            request
            for request in verified_requests
            if request.get("source_url") != urlsplit(ACADEMIC_URL).path
            and request.get("stable_for_current_account") is True
            and request.get("contains_course_details") is True
        ),
        None,
    )
    if verified_dynamic:
        return {
            "result": "courses_loaded_by_verified_dynamic_request",
            "initial_html_has_course_rows": False,
            "verified_dynamic_source": {
                "source_url": verified_dynamic.get("source_url"),
                "method": verified_dynamic.get("method"),
                "content_type": verified_dynamic.get("content_type"),
                "required_parameters": verified_dynamic.get("required_parameters", []),
            },
        }
    unresolved_candidates = [
        request
        for request in verified_requests
        if request.get("source_url") != urlsplit(ACADEMIC_URL).path
        and request.get("kind") != "menu"
    ]
    has_markers = (
        any(academic_structure.get("script_marker_counts", {}).values())
        or bool(academic_structure.get("data_sources"))
        or bool(academic_structure.get("iframe_sources"))
        or bool(unresolved_candidates)
    )
    return {
        "result": (
            "dynamic_candidates_not_verified"
            if has_markers
            else "no_course_source_found"
        ),
        "initial_html_has_course_rows": False,
        "dynamic_markers_present": has_markers,
        "unverified_candidate_count": len(unresolved_candidates),
        "verified_dynamic_source": None,
    }


def _graduation_complete(candidate: Mapping[str, Any]) -> bool:
    has_required_fields_and_values = all(
        candidate.get(key) is True
        for key in (
            "contains_module_groups",
            "contains_required_credits",
            "contains_earned_credits",
            "contains_remaining_credits",
            "has_non_empty_required_credits",
            "has_non_empty_earned_credits",
            "has_non_empty_remaining_credits",
        )
    )
    has_detail_record = (
        candidate.get("has_non_empty_module_record") is True
        or candidate.get("has_non_empty_course_record") is True
    )
    return has_required_fields_and_values and has_detail_record


def build_cross_sample_summary(reports: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    if any(report.get("probe_version") != PROBE_VERSION for report in reports):
        raise ValueError("报告版本不一致或不是学业数据源探针输出")
    sample_ids = [
        str(_safe_alias(report.get("sample", {}).get("id"), "sample.id"))
        for report in reports
    ]
    if not reports or not all(sample_ids) or len(sample_ids) != len(set(sample_ids)):
        raise ValueError("报告必须包含互不重复的匿名 sample id")

    cohorts = {
        str(_safe_alias(report["sample"].get("cohort_alias"), "sample.cohort_alias"))
        for report in reports
        if report["sample"].get("cohort_alias")
    }
    majors = {
        str(_safe_alias(report["sample"].get("major_alias"), "sample.major_alias"))
        for report in reports
        if report["sample"].get("major_alias")
    }
    colleges = {
        str(
            _safe_alias(
                report["sample"].get("college_alias"),
                "sample.college_alias",
                required=False,
            )
        )
        for report in reports
        if report["sample"].get("college_alias")
    }
    coverage_met = len(reports) >= 2 and len(cohorts) >= 2 and len(majors) >= 2

    per_report: list[dict[tuple[str, str], Mapping[str, Any]]] = []
    for report in reports:
        per_report.append(
            {
                (str(item.get("method")), str(item.get("source_url"))): item
                for item in report.get("verified_requests", [])
                if item.get("stable_for_current_account") is True
            }
        )
    common_keys = set(per_report[0])
    for mapping in per_report[1:]:
        common_keys.intersection_update(mapping)

    stable_sources: list[dict[str, Any]] = []
    for key in sorted(common_keys):
        items = [mapping[key] for mapping in per_report]
        signatures = {str(item.get("structure_signature")) for item in items}
        stable_sources.append(
            {
                "method": key[0],
                "source_url": key[1],
                "content_types": sorted(
                    {str(item.get("content_type")) for item in items}
                ),
                "same_structure_across_samples": len(signatures) == 1,
                "graduation_fields_complete": all(
                    _graduation_complete(item) for item in items
                ),
            }
        )

    qualified = [
        source
        for source in stable_sources
        if source["same_structure_across_samples"]
        and source["graduation_fields_complete"]
    ]
    route = None
    status = "INCONCLUSIVE"
    reason = "尚未达到至少 2 个年级和 2 个专业的授权样本覆盖"
    probes_complete = all(
        report.get("probe_completeness", {}).get("complete") is True
        for report in reports
    )
    if coverage_met:
        json_source = next(
            (
                source
                for source in qualified
                if any("json" in value for value in source["content_types"])
            ),
            None,
        )
        html_source = next(
            (
                source
                for source in qualified
                if any("html" in value for value in source["content_types"])
            ),
            None,
        )
        if json_source:
            route = "A"
            status = "READY"
            reason = "找到并跨样本验证了官方毕业完成度结构化接口"
        elif html_source:
            route = "B"
            status = "READY"
            reason = "未找到独立结构化接口，但存在跨样本稳定的官方完成度页面"
        elif probes_complete:
            route = "C"
            status = "READY"
            reason = "授权样本中未发现可跨样本验证的官方毕业完成度来源"
        else:
            reason = "多样本覆盖已满足，但仍有候选请求或菜单未完成验证"

    return {
        "probe_version": PROBE_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "sample_count": len(reports),
        "sample_ids": sorted(sample_ids),
        "coverage": {
            "cohort_count": len(cohorts),
            "major_count": len(majors),
            "college_count": len(colleges),
            "minimum_met": coverage_met,
            "preferred_two_colleges_met": len(colleges) >= 2,
        },
        "all_probes_complete": probes_complete,
        "stable_sources": stable_sources,
        "decision_status": status,
        "route": route,
        "reason": reason,
    }


def render_cross_sample_report(
    summary: Mapping[str, Any],
    reports: Sequence[Mapping[str, Any]],
) -> str:
    verified_menus = sorted(
        {
            (
                str(item.get("method") or "-"),
                str(item.get("source_url") or "未发现 URL"),
            )
            for report in reports
            for item in report.get("menu_candidates", [])
            if item.get("verification_status") == "verified_business_response"
        }
    )
    verified_requests = sorted(
        {
            (
                str(item.get("method") or "-"),
                str(item.get("source_url") or "-"),
                str(item.get("content_type") or "-"),
            )
            for report in reports
            for item in report.get("verified_requests", [])
            if item.get("stable_for_current_account") is True
        }
    )
    unverified_candidates = sorted(
        {
            (
                str(item.get("method") or "-"),
                str(item.get("source_url") or "-"),
                str(item.get("verification_status") or "unknown"),
            )
            for report in reports
            for item in report.get("unverified_candidates", [])
        }
    )
    diagnoses = [
        (
            str(report.get("sample", {}).get("id") or "unknown"),
            str(report.get("courses_empty_diagnosis", {}).get("result") or "unknown"),
        )
        for report in reports
    ]
    route = summary.get("route") or "未判定"
    next_stage = {
        "A": "阶段 3B：官方毕业数据模型与解析",
        "B": "阶段 3B：官方 HTML 毕业完成度解析",
        "C": "阶段 4A：人工审核培养方案规则包",
    }.get(str(summary.get("route")), "继续补充授权样本，不进入正式毕业预警开发")

    lines = [
        "# 阶段 3A.2 学业与毕业数据源探测报告",
        "",
        "## 1. 探测范围",
        f"- 授权匿名样本：{summary['sample_count']} 个",
        f"- 最低多样本覆盖：{'满足' if summary['coverage']['minimum_met'] else '未满足'}",
        f"- 两学院优选覆盖：{'满足' if summary['coverage']['preferred_two_colleges_met'] else '未满足'}",
        "",
        "## 2. 已验证菜单",
    ]
    lines.extend(
        [f"- `{method} {path}`" for method, path in verified_menus]
        or ["- 未发现含业务响应的已验证候选菜单"]
    )
    lines.extend(["", "## 3. 已验证请求"])
    lines.extend(
        [
            f"- `{method} {path}`，`{content_type}`"
            for method, path, content_type in verified_requests
        ]
        or ["- 未发现含业务字段的已验证请求"]
    )
    lines.extend(
        [
            f"- 未验证候选：`{method} {path}`，`{status}`"
            for method, path, status in unverified_candidates
        ]
    )
    lines.extend(["", "## 4. courses=[] 原因"])
    lines.extend(f"- `{sample_id}`：`{result}`" for sample_id, result in diagnoses)
    lines.extend(
        [
            "",
            "## 5. 独立毕业接口结论",
            f"- 判定状态：`{summary['decision_status']}`",
            f"- 路线：`{route}`",
            f"- 原因：{summary['reason']}",
            "",
            "## 6. 多专业多年级差异",
            f"- 年级匿名类别：{summary['coverage']['cohort_count']}",
            f"- 专业匿名类别：{summary['coverage']['major_count']}",
            f"- 学院匿名类别：{summary['coverage']['college_count']}",
            f"- 跨样本稳定来源：{len(summary['stable_sources'])}",
            "",
            "## 7. 隐私和安全检查",
            "- 未保存 Cookie、密码、学号、姓名、身份证号、完整 HTML 或响应字段值。",
            "- GET 仅验证同源只读候选；POST 只有精确路径经 `--allow-post` 明确授权后才会发出。",
            "",
            "## 8. 最终路线 A / B / C",
            f"- `{route}`",
            "",
            "## 9. 下一阶段建议",
            f"- {next_stage}",
            "",
        ]
    )
    return "\n".join(lines)


def _ensure_private_output(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    ignore_file = directory / ".gitignore"
    if not ignore_file.exists():
        ignore_file.write_text("*\n!.gitignore\n", encoding="ascii")


def _assert_no_credentials(report: Mapping[str, Any], secrets: Sequence[str]) -> None:
    serialized = json.dumps(report, ensure_ascii=False, sort_keys=True)
    for secret in secrets:
        if secret and len(secret) >= 4 and secret in serialized:
            raise RuntimeError("脱敏检查失败：输出包含登录凭据或账号标识")


def _write_report(path: Path, report: Mapping[str, Any], *, overwrite: bool) -> None:
    _ensure_private_output(path.parent)
    if path.exists() and not overwrite:
        raise FileExistsError(f"输出已存在：{path}；如需覆盖请添加 --overwrite")
    path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True),
        encoding="utf-8",
    )


def _write_text(path: Path, content: str, *, overwrite: bool) -> None:
    _ensure_private_output(path.parent)
    if path.exists() and not overwrite:
        raise FileExistsError(f"输出已存在：{path}；如需覆盖请添加 --overwrite")
    path.write_text(content, encoding="utf-8")


async def _run_probe(args: argparse.Namespace) -> int:
    sample = {
        "id": _safe_alias(args.sample_id, "--sample-id"),
        "cohort_alias": _safe_alias(args.cohort_alias, "--cohort-alias"),
        "major_alias": _safe_alias(args.major_alias, "--major-alias"),
        "college_alias": _safe_alias(
            args.college_alias, "--college-alias", required=False
        ),
    }
    student_id = input("教务学号（仅用于本次登录，不保存）：").strip()
    password = getpass.getpass("教务密码（不会显示或保存）：").strip()
    if not student_id or not password:
        raise ValueError("学号和密码不能为空")

    async with EduCrawler(timeout=args.timeout) as crawler:
        cookie = await crawler.login(student_id, password)
        password_secret = password
        password = ""
        probe = AcademicSourceProbe(
            crawler.client,
            cookie,
            allowed_post_paths=args.allow_post,
        )
        report = await probe.run(sample)

    cookie_values = tuple(
        part.partition("=")[2]
        for part in cookie.split(";")
        if "=" in part and part.partition("=")[2]
    )
    _assert_no_credentials(
        report,
        (student_id, password_secret, cookie, *cookie_values),
    )
    output_dir = Path(args.output_dir).resolve()
    output_path = output_dir / f"{sample['id']}.json"
    _write_report(output_path, report, overwrite=args.overwrite)
    print(f"脱敏探测完成：{output_path}")
    print("未保存 Cookie、密码、学号、个人页面文本或完整 HTML。")
    return 0


def _merge_reports(args: argparse.Namespace) -> int:
    reports = [
        json.loads(Path(path).read_text(encoding="utf-8")) for path in args.reports
    ]
    summary = build_cross_sample_summary(reports)
    output_path = Path(args.output).resolve()
    markdown_path = output_path.with_suffix(".md")
    if not args.overwrite:
        existing = [path for path in (output_path, markdown_path) if path.exists()]
        if existing:
            raise FileExistsError(
                f"输出已存在：{existing[0]}；如需覆盖请添加 --overwrite"
            )
    _write_report(output_path, summary, overwrite=args.overwrite)
    _write_text(
        markdown_path,
        render_cross_sample_report(summary, reports),
        overwrite=args.overwrite,
    )
    print(f"跨样本汇总完成：{output_path}")
    print(f"九节脱敏报告：{markdown_path}")
    print(
        f"结论状态：{summary['decision_status']}，路线：{summary['route'] or '未判定'}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="仅用于阶段 3A.2 的同源、只读、脱敏教务数据源探测"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="使用一个本人授权账号执行探测")
    run_parser.add_argument(
        "--sample-id", required=True, help="匿名样本编号，如 sample-a"
    )
    run_parser.add_argument(
        "--cohort-alias", required=True, help="匿名年级标签，如 cohort-a"
    )
    run_parser.add_argument(
        "--major-alias", required=True, help="匿名专业标签，如 major-a"
    )
    run_parser.add_argument("--college-alias", help="匿名学院标签，如 college-a")
    run_parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    run_parser.add_argument("--timeout", type=float, default=20.0)
    run_parser.add_argument(
        "--allow-post",
        action="append",
        default=[],
        type=_allowed_post_path,
        metavar="PATH",
        help="人工确认只读后允许执行的 POST 绝对路径；可重复指定",
    )
    run_parser.add_argument("--overwrite", action="store_true")

    merge_parser = subparsers.add_parser("merge", help="合并多个脱敏样本并判定 A/B/C")
    merge_parser.add_argument("reports", nargs="+", help="至少两个脱敏样本 JSON")
    merge_parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT_DIR / "cross-sample-summary.json"),
    )
    merge_parser.add_argument("--overwrite", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "merge":
            return _merge_reports(args)
        return asyncio.run(_run_probe(args))
    except (
        ValueError,
        FileExistsError,
        LoginFailedError,
        NetworkError,
        RuntimeError,
    ) as exc:
        print(f"探测失败：{exc}", file=sys.stderr)
        return 1
    except httpx.HTTPError as exc:
        print(f"探测失败：教务网络请求异常（{type(exc).__name__}）", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
