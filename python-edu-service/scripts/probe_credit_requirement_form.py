"""验证学籍预警页面的真实查询表单协议。

该脚本仅用于服务器侧诊断：复用数据库中已加密保存的教务 Cookie，
不输出 Cookie、学号、姓名、字段值或页面正文。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
from dataclasses import asdict, dataclass
from urllib.parse import urljoin

from bs4 import BeautifulSoup, Tag
from sqlalchemy import select

from models.database import AsyncSessionLocal, EduUser
from services.crawler import (
    ACADEMIC_REQUIREMENT_URL,
    EduCrawler,
    _normalize_text,
    parse_credit_requirement_html,
)
from services.security import decrypt_credential


ACADEMIC_REQUIREMENT_QUERY_URL = (
    "https://jxw.sylu.edu.cn/xjyj/xjyj_cxXjyjjdlb.html"
)


@dataclass(frozen=True)
class FormDescriptor:
    index: int
    form_id: str
    method: str
    action: str
    control_names: list[str]
    button_ids: list[str]
    button_names: list[str]
    event_attributes: list[str]


def _page_summary(body: str) -> dict[str, object]:
    soup = BeautifulSoup(body or "", "html.parser")
    text = _normalize_text(soup.get_text(" ", strip=True))
    parsed = parse_credit_requirement_html(body)
    return {
        "body_length": len(body or ""),
        "forms": len(soup.select("form")),
        "tables": len(soup.select("table")),
        "has_query": "查询" in text,
        "has_minimum": "要求最低" in text,
        "has_improvement": "提高课程" in text,
        "parse_success": bool(parsed.get("success")),
        "parse_status": parsed.get("status"),
        "module_count": len(parsed.get("modules") or []),
        "improvement_course_count": len(
            parsed.get("improvement_courses") or []
        ),
    }


def _describe_forms(soup: BeautifulSoup, base_url: str) -> list[FormDescriptor]:
    descriptors: list[FormDescriptor] = []
    for index, form in enumerate(soup.select("form")):
        controls = form.select("input[name],select[name],textarea[name],button[name]")
        buttons = form.select("button,input[type='submit'],input[type='button']")
        event_attributes = sorted(
            {
                name
                for button in buttons
                for name in button.attrs
                if name.lower().startswith("on")
            }
        )
        descriptors.append(
            FormDescriptor(
                index=index,
                form_id=str(form.get("id") or ""),
                method=str(form.get("method") or "get").lower(),
                action=urljoin(base_url, str(form.get("action") or base_url)),
                control_names=sorted(
                    {str(control.get("name")) for control in controls}
                ),
                button_ids=sorted(
                    {
                        str(button.get("id"))
                        for button in buttons
                        if button.get("id")
                    }
                ),
                button_names=sorted(
                    {
                        str(button.get("name"))
                        for button in buttons
                        if button.get("name")
                    }
                ),
                event_attributes=event_attributes,
            )
        )
    return descriptors


def _script_candidate_literals(source: str) -> list[str]:
    quoted = re.findall(r"['\"]([^'\"]{1,240})['\"]", source or "")
    return sorted(
        {
            item
            for item in quoted
            if any(
                token in item.lower()
                for token in ("xjyj", ".html", "search_go", "dotype", "query")
            )
            and not item.lower().startswith("javascript:")
        }
    )


def _script_diagnostics(soup: BeautifulSoup) -> dict[str, object]:
    """只提取查询脚本的结构线索，不输出脚本正文。"""
    scripts = soup.select("script")
    inline = [script.get_text(" ", strip=True) for script in scripts]
    combined = "\n".join(inline)
    relevant_inline = [
        index
        for index, source in enumerate(inline)
        if any(token in source.lower() for token in ("search_go", "xjyj", "ajax"))
    ]
    return {
        "script_count": len(scripts),
        "external_script_sources": sorted(
            {
                str(script.get("src"))
                for script in scripts
                if script.get("src")
            }
        ),
        "relevant_inline_script_indexes": relevant_inline,
        "endpoint_candidates": _script_candidate_literals(combined),
        "ajax_markers": sorted(
            marker
            for marker in ("$.ajax", "$.post", "$.get", "fetch(", ".load(", ".submit(")
            if marker.lower() in combined.lower()
        ),
        "search_node_attribute_names": sorted(
            {
                name
                for node in soup.select("#search_go")
                for name in node.attrs
            }
        ),
    }


async def _external_script_diagnostics(
    crawler: EduCrawler,
    soup: BeautifulSoup,
    base_url: str,
    headers: dict[str, str],
) -> list[dict[str, object]]:
    """抓取页面专用脚本，仅返回接口字面量和关键标记。"""
    if crawler.client is None:
        return []

    diagnostics: list[dict[str, object]] = []
    for script in soup.select("script[src]"):
        source = str(script.get("src") or "")
        if "/xjyj/" not in source.lower():
            continue
        url = urljoin(base_url, source.replace("\\", "/"))
        response = await crawler.client.get(url, headers=headers)
        response.raise_for_status()
        body = response.text or ""
        diagnostics.append(
            {
                "url": url,
                "body_length": len(body),
                "candidate_literals": _script_candidate_literals(body),
                "markers": sorted(
                    marker
                    for marker in (
                        "search_go",
                        "$.ajax",
                        "$.post",
                        "$.get",
                        "fetch(",
                        ".load(",
                        "doType",
                    )
                    if marker.lower() in body.lower()
                ),
            }
        )
    return diagnostics


def _query_form(soup: BeautifulSoup) -> Tag:
    candidates = [
        form
        for form in soup.select("form")
        if "查询" in _normalize_text(form.get_text(" ", strip=True))
        or any(
            "search" in str(node.get("id") or "").lower()
            or "query" in str(node.get("id") or "").lower()
            for node in form.select("button,input")
        )
    ]
    if len(candidates) != 1:
        raise RuntimeError(f"无法唯一识别查询表单: candidates={len(candidates)}")
    return candidates[0]


def _selected_option_value(select_node: Tag) -> str:
    selected = select_node.select_one("option[selected]")
    if selected is None:
        selected = next(
            (
                option
                for option in select_node.select("option")
                if str(option.get("value") or "").strip()
            ),
            None,
        )
    return str(selected.get("value") or "") if selected else ""


def _form_payload(form: Tag) -> dict[str, str]:
    payload: dict[str, str] = {}
    for control in form.select("input[name],select[name],textarea[name]"):
        name = str(control.get("name") or "").strip()
        if not name or control.has_attr("disabled"):
            continue
        if control.name == "select":
            payload[name] = _selected_option_value(control)
            continue
        control_type = str(control.get("type") or "text").lower()
        if control_type in {"button", "submit", "reset", "file"}:
            continue
        if control_type in {"checkbox", "radio"} and not control.has_attr(
            "checked"
        ):
            continue
        payload[name] = str(control.get("value") or "")

    query_buttons = [
        button
        for button in form.select("button[name],input[type='submit'][name]")
        if "查询" in _normalize_text(button.get_text(" ", strip=True))
        or "search" in str(button.get("id") or "").lower()
        or "query" in str(button.get("id") or "").lower()
    ]
    if len(query_buttons) == 1:
        button = query_buttons[0]
        payload[str(button.get("name"))] = str(button.get("value") or "")
    return payload


def _json_structure(value: object) -> dict[str, object]:
    """汇总 JSON 树形结构，不输出任何业务字段值。"""
    root_items = value if isinstance(value, list) else []
    object_keys: set[str] = set()
    list_keys: set[str] = set()
    object_count = 0
    course_count = 0

    def visit(node: object) -> None:
        nonlocal object_count, course_count
        if isinstance(node, dict):
            object_count += 1
            object_keys.update(str(key) for key in node)
            if any(key in node for key in ("kch", "kcmc", "xf")):
                course_count += 1
            for key, child in node.items():
                if isinstance(child, list):
                    list_keys.add(str(key))
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(value)
    return {
        "root_type": type(value).__name__,
        "root_count": len(root_items),
        "object_count": object_count,
        "course_count": course_count,
        "object_keys": sorted(object_keys),
        "list_keys": sorted(list_keys),
    }


async def _load_cookie(user_id: str) -> str:
    async with AsyncSessionLocal() as db:
        result = await db.execute(
            select(EduUser).where(EduUser.user_id == user_id)
        )
        edu_user = result.scalar_one_or_none()
        if edu_user is None or not edu_user.cookie:
            raise RuntimeError("指定用户没有可用的教务会话")
        return decrypt_credential(edu_user.cookie)


async def probe(user_id: str, timeout: float) -> dict[str, object]:
    cookie = await _load_cookie(user_id)
    headers = {
        "Cookie": cookie,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Referer": "https://jxw.sylu.edu.cn/xtgl/index_initMenu.html",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
    }

    async with EduCrawler(timeout=timeout) as crawler:
        if crawler.client is None:
            raise RuntimeError("HTTP 客户端初始化失败")
        entry = await crawler.client.get(
            ACADEMIC_REQUIREMENT_URL,
            params={"gnmkdm": "N105505", "layout": "default"},
            headers=headers,
        )
        entry.raise_for_status()
        soup = BeautifulSoup(entry.text or "", "html.parser")
        descriptors = _describe_forms(soup, str(entry.url))
        external_scripts = await _external_script_diagnostics(
            crawler,
            soup,
            str(entry.url),
            headers,
        )
        form = _query_form(soup)
        method = str(form.get("method") or "get").lower()
        action = urljoin(str(entry.url), str(form.get("action") or entry.url))
        payload = _form_payload(form)
        ajax_payload = {
            key: payload.get(key, "")
            for key in ("jg_id", "njdm_id", "zyh_id")
        }
        query_headers = {
            **headers,
            "Referer": str(entry.url),
        }

        ajax_result = await crawler.client.post(
            ACADEMIC_REQUIREMENT_QUERY_URL,
            data=ajax_payload,
            headers={
                **query_headers,
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "X-Requested-With": "XMLHttpRequest",
            },
        )
        ajax_result.raise_for_status()
        ajax_json = ajax_result.json()

        if method == "post":
            result = await crawler.client.post(
                action,
                data=payload,
                headers=query_headers,
            )
        elif method == "get":
            result = await crawler.client.get(
                action,
                params=payload,
                headers=query_headers,
            )
        else:
            raise RuntimeError(f"不支持的表单方法: {method}")
        result.raise_for_status()

    return {
        "entry": _page_summary(entry.text),
        "forms": [asdict(item) for item in descriptors],
        "scripts": _script_diagnostics(soup),
        "external_scripts": external_scripts,
        "selected_form": {
            "method": method,
            "action": action,
            "payload_fields": sorted(payload),
        },
        "ajax_result": {
            "status_code": ajax_result.status_code,
            "content_type": ajax_result.headers.get("content-type", ""),
            "body_length": len(ajax_result.text or ""),
            "structure": _json_structure(ajax_json),
        },
        "result": _page_summary(result.text),
        "result_url": str(result.url),
        "result_content_type": result.headers.get("content-type", ""),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    result = asyncio.run(probe(args.user_id, args.timeout))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
