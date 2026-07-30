"""Catalog 2.2 的离线规范化、摘要和结构校验。"""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterable, Mapping
from datetime import date, datetime, timezone
from typing import Any

SCHEMA_VERSION = "sylulive-competition-catalog/2.2"
HASH_FIELDS = (
    "competition_id",
    "parent_competition_id",
    "record_hash",
    "catalog_order",
    "title",
    "subtitle",
    "summary",
    "description",
    "primary_category_slug",
    "tags",
    "competition_level",
    "school_recognition_status",
    "school_recognition_grade",
    "competition_rating",
    "importance_score",
    "organizer",
    "host_unit",
    "target_audience",
    "eligible_entry_years",
    "eligible_colleges",
    "eligible_majors",
    "participation_type",
    "team_size_min",
    "team_size_max",
    "registration_start",
    "registration_end",
    "event_start",
    "event_end",
    "registration_time_text",
    "event_time_text",
    "time_precision",
    "time_status",
    "time_note",
    "sort_month",
    "location",
    "is_online",
    "official_url",
    "notice_url",
    "source_channel",
    "source_note",
    "status",
    "manual_rating_reason_public",
    "major_fit_summary_public",
    "evidence_summary_public",
    "evidence_subgrade",
    "risk_tags",
    "search_display_allowed",
    "candidate_pool_allowed",
    "personalized_ranking_allowed",
    "strong_recommendation_eligible",
    "recommendation_permission_level",
    "ai_mode",
    "blocker_codes",
)
OPTIONAL_STRING_FIELDS = {
    "parent_competition_id",
    "subtitle",
    "summary",
    "description",
    "primary_category_slug",
    "competition_level",
    "school_recognition_status",
    "school_recognition_grade",
    "competition_rating",
    "organizer",
    "host_unit",
    "target_audience",
    "participation_type",
    "registration_start",
    "registration_end",
    "event_start",
    "event_end",
    "registration_time_text",
    "event_time_text",
    "time_note",
    "location",
    "official_url",
    "notice_url",
    "source_channel",
    "source_note",
    "manual_rating_reason_public",
    "major_fit_summary_public",
    "evidence_summary_public",
    "evidence_subgrade",
}
ARRAY_FIELDS = {
    "tags",
    "eligible_entry_years",
    "eligible_colleges",
    "eligible_majors",
    "risk_tags",
    "blocker_codes",
}
BOOL_FIELDS = {
    "is_online",
    "search_display_allowed",
    "candidate_pool_allowed",
    "personalized_ranking_allowed",
    "strong_recommendation_eligible",
}
INT_FIELDS = {
    "catalog_order",
    "importance_score",
    "team_size_min",
    "team_size_max",
    "sort_month",
}


def canonical_json(value: Any) -> bytes:
    """复现 Go encoding/json 的紧凑 UTF-8 编码。"""

    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _string(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _integer(value: Any) -> int:
    if value is None or _string(value) == "":
        return 0
    if isinstance(value, bool):
        raise ValueError("布尔值不能作为整数")
    number = float(value)
    if not number.is_integer():
        raise ValueError(f"整数列不能包含小数: {value!r}")
    return int(number)


def _boolean(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    normalized = _string(value).lower()
    if normalized in {"true", "1", "yes", "y", "是"}:
        return True
    if normalized in {"false", "0", "no", "n", "否", ""}:
        return False
    raise ValueError(f"布尔列无效: {value!r}")


def _array(value: Any) -> list[str]:
    if value is None or _string(value) == "":
        return []
    if isinstance(value, list):
        raw = value
    else:
        text = _string(value)
        if text.startswith("["):
            raw = json.loads(text)
            if not isinstance(raw, list):
                raise ValueError("数组列的 JSON 必须是数组")
        else:
            separator = "|" if "|" in text else "\n" if "\n" in text else ","
            raw = text.split(separator)
    result: list[str] = []
    seen: set[str] = set()
    for item in raw:
        normalized = _string(item)
        if normalized and normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def _date_text(value: Any) -> str:
    if value is None or _string(value) == "":
        return ""
    if isinstance(value, datetime):
        if value.tzinfo is not None:
            return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        return value.date().isoformat()
    if isinstance(value, date):
        return value.isoformat()
    text = _string(value)
    try:
        if len(text) == 10:
            return date.fromisoformat(text).isoformat()
        return (
            datetime.fromisoformat(text.replace("Z", "+00:00"))
            .astimezone(timezone.utc)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except ValueError as exc:
        raise ValueError(f"日期必须是 YYYY-MM-DD 或 RFC3339: {text}") from exc


def normalize_record(raw: Mapping[str, Any]) -> dict[str, Any]:
    """按 Go DTO 声明顺序构造规范记录。"""

    unknown = set(raw) - set(HASH_FIELDS)
    if unknown:
        raise ValueError(f"包含未知字段: {', '.join(sorted(unknown))}")
    normalized: dict[str, Any] = {}
    for field in HASH_FIELDS:
        value = raw.get(field)
        if field in ARRAY_FIELDS:
            value = _array(value)
        elif field in BOOL_FIELDS:
            value = _boolean(value)
        elif field in INT_FIELDS:
            value = _integer(value)
        elif field in {"registration_start", "registration_end", "event_start", "event_end"}:
            value = _date_text(value)
        else:
            value = _string(value)
            if field == "competition_rating":
                value = value.upper()
        if field in OPTIONAL_STRING_FIELDS and value == "":
            continue
        normalized[field] = value
    return normalized


def compute_record_hash(record: Mapping[str, Any]) -> str:
    normalized = normalize_record(record)
    normalized.pop("record_hash", None)
    encoded = json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def compute_package_hash(document: Mapping[str, Any]) -> str:
    records = sorted(
        (
            {
                "competition_id": _string(item.get("competition_id")),
                "record_hash": _string(item.get("record_hash")),
            }
            for item in document.get("items", [])
        ),
        key=lambda item: item["competition_id"],
    )
    payload = {
        "schema_version": _string(document.get("schema_version")),
        "dataset_version": _string(document.get("dataset_version")),
        "publish_status": _string(document.get("publish_status")),
        "production_load_allowed": _boolean(document.get("production_load_allowed")),
        "item_count": _integer(document.get("item_count")),
        "records": records,
    }
    return hashlib.sha256(canonical_json(payload)).hexdigest()


def build_document(
    rows: Iterable[Mapping[str, Any]],
    *,
    dataset_version: str,
    publish_status: str,
    production_load_allowed: bool,
    source_filename: str,
) -> dict[str, Any]:
    items: list[dict[str, Any]] = []
    for raw in rows:
        record = normalize_record(raw)
        record["record_hash"] = compute_record_hash(record)
        record = normalize_record(record)
        items.append(record)
    document: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "dataset_version": dataset_version.strip(),
        "package_hash": "",
        "publish_status": publish_status.strip(),
        "production_load_allowed": production_load_allowed,
        "item_count": len(items),
        "source_filename": source_filename,
        "items": items,
    }
    document["package_hash"] = compute_package_hash(document)
    return document


def validate_document(document: Mapping[str, Any]) -> list[str]:
    """返回确定性错误列表；空列表表示可交给 Go 再校验。"""

    errors: list[str] = []
    if document.get("schema_version") != SCHEMA_VERSION:
        errors.append(f"schema_version 必须为 {SCHEMA_VERSION}")
    if not _string(document.get("dataset_version")):
        errors.append("dataset_version 不能为空")
    if document.get("publish_status") not in {"draft", "published"}:
        errors.append("publish_status 只能是 draft 或 published")
    items = document.get("items")
    if not isinstance(items, list):
        return [*errors, "items 必须是数组"]
    if document.get("item_count") != len(items):
        errors.append("item_count 与实际记录数不一致")

    records: dict[str, Mapping[str, Any]] = {}
    for index, raw in enumerate(items, 1):
        if not isinstance(raw, Mapping):
            errors.append(f"第 {index} 条记录必须是对象")
            continue
        try:
            record = normalize_record(raw)
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"第 {index} 条记录规范化失败: {exc}")
            continue
        competition_id = record.get("competition_id", "")
        if not competition_id or len(competition_id) > 64:
            errors.append(f"第 {index} 条 competition_id 无效")
        elif competition_id in records:
            errors.append(f"competition_id 重复: {competition_id}")
        records[competition_id] = record
        if not record.get("title"):
            errors.append(f"{competition_id}: title 不能为空")
        if record.get("status") not in {"published", "draft", "archived"}:
            errors.append(f"{competition_id}: status 枚举无效")
        if record.get("time_precision") not in {
            "exact",
            "month",
            "month_range",
            "quarter",
            "half_year",
            "season",
            "unknown",
        }:
            errors.append(f"{competition_id}: time_precision 枚举无效")
        if record.get("time_status") not in {"confirmed", "estimated", "historical", "pending"}:
            errors.append(f"{competition_id}: time_status 枚举无效")
        if record.get("recommendation_permission_level") not in {"blocked", "low", "medium", "high"}:
            errors.append(f"{competition_id}: recommendation_permission_level 枚举无效")
        if record.get("ai_mode") not in {
            "disabled",
            "catalog_only",
            "candidate_explanation",
            "selected_comparison",
        }:
            errors.append(f"{competition_id}: ai_mode 枚举无效")
        if not record.get("candidate_pool_allowed") and (
            record.get("personalized_ranking_allowed")
            or record.get("strong_recommendation_eligible")
        ):
            errors.append(f"{competition_id}: 未进入候选池时不能开放排序或强推荐")
        if record.get("strong_recommendation_eligible") and (
            record.get("recommendation_permission_level") != "high"
            or not record.get("personalized_ranking_allowed")
            or record.get("blocker_codes")
        ):
            errors.append(f"{competition_id}: 强推荐权限组合无效")
        computed = compute_record_hash(record)
        if record.get("record_hash") != computed:
            errors.append(f"{competition_id}: record_hash 不匹配")

    for competition_id, record in records.items():
        parent = record.get("parent_competition_id", "")
        if parent and parent not in records:
            errors.append(f"{competition_id}: 父赛事 {parent} 不存在")
    for competition_id in records:
        seen: set[str] = set()
        current = competition_id
        while current:
            if current in seen:
                errors.append(f"{competition_id}: 父赛事引用形成循环")
                break
            seen.add(current)
            current = _string(records.get(current, {}).get("parent_competition_id"))

    try:
        computed_package = compute_package_hash(document)
        if document.get("package_hash") != computed_package:
            errors.append("package_hash 不匹配")
    except (TypeError, ValueError) as exc:
        errors.append(f"package_hash 复算失败: {exc}")
    return sorted(set(errors))
