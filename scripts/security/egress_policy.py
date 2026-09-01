#!/usr/bin/env python3
"""学校权限迁移的出站网络证据策略。

本模块只校验已经脱敏的审计记录，不执行 DNS、HTTP 或防火墙操作。它把应用层
记录转换为可复核的 allow/deny 结论，并拒绝把凭据、请求体或查询秘密带入证据。
真正的边界仍必须由 egress proxy、容器网络策略或主机防火墙落实。
"""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping


SENSITIVE_FIELD_NAMES = frozenset(
    {
        "authorization",
        "cookie",
        "set_cookie",
        "body",
        "request_body",
        "response_body",
        "query_secret",
        "querysecret",
        "password",
        "school_password",
        "token",
        "access_token",
        "student_id",
        "studentid",
        "email",
        "client_ip",
        "source_ip",
        "request_ip",
        "remote_addr",
        "user_ip",
        "device_id",
        "deviceid",
        "device_identifier",
        "installation_id",
        "installationid",
    }
)

BLOCKED_DESTINATION_CLASSES = frozenset(
    {
        "school_personal",
        "rfc1918",
        "loopback",
        "link_local",
        "cloud_metadata",
        "user_controlled",
        "unknown",
    }
)

ALLOWED_DESTINATION_CLASSES = frozenset(
    {"smtp", "push", "ai_provider", "object_storage", "dns", "monitoring"}
)

_HOST_RE = re.compile(r"^[A-Za-z0-9._:[\]%-]+$")


@dataclass(frozen=True)
class EgressIssue:
    """不含主机值或敏感内容的稳定问题码。"""

    code: str


def _sensitive_fields(value: Any, prefix: str = "") -> set[str]:
    found: set[str] = set()
    if isinstance(value, Mapping):
        for key, nested in value.items():
            key_text = str(key).strip().lower().replace("-", "_")
            path = f"{prefix}.{key_text}" if prefix else key_text
            if key_text in SENSITIVE_FIELD_NAMES:
                found.add(key_text)
            found.update(_sensitive_fields(nested, path))
    elif isinstance(value, (list, tuple)):
        for index, nested in enumerate(value):
            found.update(_sensitive_fields(nested, f"{prefix}[{index}]"))
    return found


def _parse_ip(host: str) -> ipaddress._BaseAddress | None:
    candidate = host.strip().strip("[]")
    # Audit records may contain a host:port value; strip the port only when it is
    # unambiguous. This is validation, not a network lookup.
    if candidate.count(":") == 1:
        name, port = candidate.rsplit(":", 1)
        if port.isdigit():
            candidate = name
    try:
        return ipaddress.ip_address(candidate)
    except ValueError:
        return None


def classify_host(host: str, school_hosts: Iterable[str] = ()) -> str:
    """将主机归类为必须阻断的网络范围或普通域名。"""

    normalized = host.strip().lower().rstrip(".")
    configured_school = {
        item.strip().lower().rstrip(".")
        for item in school_hosts
        if str(item).strip()
    }
    if normalized in configured_school or any(
        normalized.endswith("." + suffix) for suffix in configured_school
    ):
        return "school_personal"
    address = _parse_ip(normalized)
    if address is None:
        return "domain"
    # 云元数据地址优先于一般 link-local 分类，便于审计明确识别。
    if str(address) == "169.254.169.254":
        return "cloud_metadata"
    if address.is_loopback:
        return "loopback"
    if address.is_link_local or address.is_private:
        return "rfc1918" if address.version == 4 else "link_local"
    if address.version == 6 and (
        address.is_unspecified
        or address.is_link_local
        or address.is_private
        or address in ipaddress.ip_network("fc00::/7")
    ):
        return "link_local"
    return "ip"


def _valid_expiry(value: Any) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed > datetime.now(timezone.utc)


def validate_egress_record(
    record: Mapping[str, Any], *, school_hosts: Iterable[str] = ()
) -> tuple[EgressIssue, ...]:
    """校验单条出站审计记录，返回稳定问题码。"""

    issues: list[EgressIssue] = []
    if _sensitive_fields(record):
        issues.append(EgressIssue("sensitive_field_present"))

    destination_class = str(record.get("destination_class", "unknown")).strip().lower()
    decision = str(record.get("decision", "")).strip().lower()
    host = str(record.get("destination_host", "")).strip()
    protocol = str(record.get("protocol", "")).strip().lower()
    port = record.get("port")

    if not host or not _HOST_RE.fullmatch(host):
        issues.append(EgressIssue("invalid_destination_host"))
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        issues.append(EgressIssue("invalid_destination_port"))
    if not protocol or protocol not in {"tcp", "udp", "http", "https", "tls", "dns"}:
        issues.append(EgressIssue("invalid_protocol"))
    if decision not in {"allow", "deny"}:
        issues.append(EgressIssue("invalid_decision"))

    inferred = classify_host(host, school_hosts)
    if destination_class in BLOCKED_DESTINATION_CLASSES:
        if decision != "deny":
            issues.append(EgressIssue("blocked_class_must_be_denied"))
    elif destination_class not in ALLOWED_DESTINATION_CLASSES:
        if decision != "deny":
            issues.append(EgressIssue("unknown_class_must_be_denied"))
    elif inferred in BLOCKED_DESTINATION_CLASSES:
        if decision != "deny":
            issues.append(EgressIssue("blocked_address_must_be_denied"))
    elif decision == "allow":
        for field in ("process", "service_account", "executable_or_image", "owner", "health_check"):
            if not str(record.get(field, "")).strip():
                issues.append(EgressIssue(f"missing_{field}"))
        if not _valid_expiry(record.get("expires_at")):
            issues.append(EgressIssue("invalid_or_expired_allowlist"))
        if record.get("dns_revalidated") is not True:
            issues.append(EgressIssue("dns_not_revalidated"))
        if record.get("network_enforced") is not True:
            issues.append(EgressIssue("external_network_boundary_missing"))

    if bool(record.get("user_controlled_destination")):
        issues.append(EgressIssue("user_controlled_destination"))
    if bool(record.get("proxy_env_bypass")) or bool(record.get("doh_bypass")):
        issues.append(EgressIssue("resolver_or_proxy_bypass"))
    if bool(record.get("redirect_revalidated")) is False and bool(record.get("redirect")):
        issues.append(EgressIssue("redirect_not_revalidated"))
    return tuple(issues)


def summarize_egress(
    records: Iterable[Mapping[str, Any]], *, school_hosts: Iterable[str] = ()
) -> dict[str, Any]:
    """生成不含敏感字段的聚合出站报告。"""

    total = allowed = denied = invalid = school_success = unknown = 0
    issue_counts: dict[str, int] = {}
    destinations: list[dict[str, Any]] = []
    for record in records:
        issues = validate_egress_record(record, school_hosts=school_hosts)
        for issue in issues:
            issue_counts[issue.code] = issue_counts.get(issue.code, 0) + 1
        decision = str(record.get("decision", "")).strip().lower()
        destination_class = str(record.get("destination_class", "unknown")).strip().lower()
        total += 1
        if decision == "allow":
            allowed += 1
        elif decision == "deny":
            denied += 1
        if issues:
            invalid += 1
        if destination_class == "school_personal" and decision == "allow" and not issues:
            school_success += 1
        # 被阻断的未知尝试可以保留在审计窗口；这里只统计实际放行的未知目的地。
        if destination_class in {"unknown", "user_controlled"} and decision == "allow":
            unknown += 1
        # Host/port are operational routing facts, not request contents. Keep
        # them only when the caller explicitly asks for an audit summary.
        destinations.append(
            {
                "destination_class": destination_class,
                "destination_host": str(record.get("destination_host", "")),
                "port": record.get("port"),
                "decision": decision,
                "issue_count": len(issues),
            }
        )
    return {
        "total_records": total,
        "allow_records": allowed,
        "deny_records": denied,
        "invalid_records": invalid,
        "school_personal_success": school_success,
        "unknown_destination_records": unknown,
        "issue_counts": dict(sorted(issue_counts.items())),
        "destinations": destinations,
    }
