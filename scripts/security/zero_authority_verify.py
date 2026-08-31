#!/usr/bin/env python3
"""PR13 ``zero-authority-verification`` 证据门禁。

脚本只消费受控验收记录和已经构建的发布物，不连接生产数据库、日志、APM 或网络。
它检查四个零、Canary、旧客户端 426、退役路由 410、egress 默认拒绝、历史清理
状态以及发布物中的 Remote/Server Academic 残留。输出只包含计数、问题码和相对
路径，不回显 Email、StudentID、Cookie、Token、请求体或 Canary 实际值。

示例（证据文件由 Release Commander 在受控环境生成）：

    python scripts/security/zero_authority_verify.py \
      --evidence release-f-evidence.json --artifact release-f.zip --pretty

没有证据文件时可用 ``--dry-run`` 查看稳定的字段契约；dry-run 不表示通过。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tarfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Sequence

try:  # 直接执行脚本时使用同目录导入；包导入时兼容相对路径。
    from egress_policy import summarize_egress
except ImportError:  # pragma: no cover - 仅在作为包导入时触发
    from .egress_policy import summarize_egress


SCHEMA_VERSION = "zero-authority-verification.v1"
COMMIT_RE = re.compile(r"^[0-9a-f]{7,64}$")

ZERO_METRICS = (
    "school_credential_server",
    "school_personal_data_server",
    "school_device_job_created",
    "server_school_login_capability",
    "device_school_personal_result",
    "server_school_personal_egress_success",
    "remote_artifact_hits",
    "server_academic_route_artifact_hits",
    "a_b_account_stream_events",
    "p0_p1_open_incidents",
)

CANARY_METRICS = (
    "student_marker_matches",
    "password_marker_matches",
    "course_marker_matches",
    "grade_marker_matches",
)

RETIRED_ROUTE_PROBES = (
    ("POST", "/api/login_edu"),
    ("POST", "/api/register_with_edu"),
    ("POST", "/api/forgot_password"),
    ("POST", "/api/password/edu/reset"),
    ("PUT", "/api/personal-snapshots/erke"),
    ("GET", "/api/personal-snapshots/erke"),
    ("DELETE", "/api/personal-snapshots/erke"),
    ("GET", "/api/edu/status"),
    ("POST", "/api/edu/bind"),
    ("DELETE", "/api/edu/bind"),
    ("POST", "/api/edu/session/logout"),
    ("POST", "/api/edu/session/resume"),
    ("DELETE", "/api/edu/authorization"),
    ("POST", "/api/edu/courses"),
    ("GET", "/api/edu/courses/local"),
    ("POST", "/api/edu/courses/sync"),
    ("POST", "/api/edu/grades"),
    ("POST", "/api/edu/grades/detail"),
    ("POST", "/api/edu/academic-situation"),
    ("POST", "/api/edu/credit-requirements"),
    ("POST", "/api/edu/pre_verify"),
)

REQUIRED_ROLES = (
    "migration_owner",
    "backend_owner",
    "client_owner",
    "dba_data_owner",
    "security_reviewer",
    "release_commander",
)

# 这些字符串在最终发布物中必须不存在。匹配只输出规则名和路径，不输出命中内容。
FORBIDDEN_ARTIFACT_PATTERNS: Mapping[str, re.Pattern[str]] = {
    "remote_academic_gateway": re.compile(r"RemoteAcademicGateway", re.IGNORECASE),
    "remote_gateway_flag": re.compile(r"ACADEMIC_GATEWAY\s*=\s*remote", re.IGNORECASE),
    "server_academic_route": re.compile(r"/api/(?:edu|personal-snapshots/erke)(?:[/\\]|\b)", re.IGNORECASE),
    "legacy_campus_verifier": re.compile(r"LegacyCampusRegistrationVerifier", re.IGNORECASE),
    "school_device_tool": re.compile(r"School\s+Device\s+Tool", re.IGNORECASE),
}

SENSITIVE_KEYS = frozenset(
    {
        "authorization",
        "cookie",
        "set_cookie",
        "body",
        "request_body",
        "response_body",
        "query_secret",
        "password",
        "school_password",
        "token",
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


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _iso_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def _as_nonnegative_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def _contains_sensitive_key(value: Any) -> bool:
    if isinstance(value, Mapping):
        for key, nested in value.items():
            normalized = str(key).strip().lower().replace("-", "_")
            if normalized in SENSITIVE_KEYS:
                return True
            if _contains_sensitive_key(nested):
                return True
    elif isinstance(value, (list, tuple)):
        return any(_contains_sensitive_key(item) for item in value)
    return False


def _contains_raw_canary(value: Any) -> bool:
    if isinstance(value, str):
        return "SYLU-ZERO-" in value.upper()
    if isinstance(value, Mapping):
        return any(_contains_raw_canary(item) for item in value.values())
    if isinstance(value, (list, tuple)):
        return any(_contains_raw_canary(item) for item in value)
    return False


def _check(check_id: str, failures: Iterable[str], details: Mapping[str, Any] | None = None) -> dict[str, Any]:
    errors = list(dict.fromkeys(str(item) for item in failures))
    result: dict[str, Any] = {
        "id": check_id,
        "status": "fail" if errors else "pass",
        "findings": [{"rule": item} for item in errors],
    }
    if details:
        result["details"] = dict(details)
    return result


def _check_metadata(evidence: Mapping[str, Any]) -> dict[str, Any]:
    release = evidence.get("release")
    failures: list[str] = []
    if not isinstance(release, Mapping):
        return _check("release-record", ["release_record_missing"])
    commit_sha = str(release.get("commit_sha", "")).lower()
    if not COMMIT_RE.fullmatch(commit_sha):
        failures.append("invalid_commit_sha")
    if not _iso_timestamp(release.get("recorded_at")):
        failures.append("invalid_recorded_at")
    if not str(release.get("release", "")).strip():
        failures.append("release_name_missing")
    roles = evidence.get("roles_signed", release.get("roles_signed", {}))
    if not isinstance(roles, Mapping):
        failures.append("roles_signed_missing")
    else:
        for role in REQUIRED_ROLES:
            if not str(roles.get(role, "")).strip():
                failures.append(f"role_missing:{role}")
    return _check("release-record", failures)


def _check_zero_metrics(evidence: Mapping[str, Any]) -> dict[str, Any]:
    metrics = evidence.get("metrics")
    failures: list[str] = []
    values: dict[str, int] = {}
    if not isinstance(metrics, Mapping):
        return _check("four-zero-metrics", ["metrics_missing"])
    for name in ZERO_METRICS:
        value = _as_nonnegative_int(metrics.get(name))
        if value is None:
            failures.append(f"metric_missing_or_invalid:{name}")
            continue
        values[name] = value
        if value != 0:
            failures.append(f"metric_nonzero:{name}")
    return _check("four-zero-metrics", failures, {"metrics": values})


def _check_canary(evidence: Mapping[str, Any]) -> dict[str, Any]:
    canary = evidence.get("canary")
    failures: list[str] = []
    values: dict[str, int] = {}
    if not isinstance(canary, Mapping):
        return _check("canary", ["canary_missing"])
    for name in CANARY_METRICS:
        raw = canary.get(name)
        if raw is None:
            # Also accept a nested ``{matches: N}`` form, useful for collectors.
            short = name.removesuffix("_matches")
            nested = canary.get(short)
            raw = nested.get("matches") if isinstance(nested, Mapping) else None
        value = _as_nonnegative_int(raw)
        if value is None:
            failures.append(f"canary_missing_or_invalid:{name}")
            continue
        values[name] = value
        if value != 0:
            failures.append(f"canary_nonzero:{name}")
    if _contains_raw_canary(canary):
        failures.append("raw_canary_marker_present")
    return _check("canary", failures, {"matches": values})


def _route_probe_key(method: str, path: str) -> tuple[str, str]:
    return method.strip().upper(), path.rstrip("/") or "/"


def _check_retired_routes(evidence: Mapping[str, Any]) -> dict[str, Any]:
    rows = evidence.get("routes")
    failures: list[str] = []
    if not isinstance(rows, list):
        return _check("retired-routes", ["routes_missing"])
    matched: dict[tuple[str, str], bool] = {probe: False for probe in RETIRED_ROUTE_PROBES}
    for row in rows:
        if not isinstance(row, Mapping):
            failures.append("route_record_invalid")
            continue
        raw_method = row.get("method")
        if not isinstance(raw_method, str) or not raw_method.strip():
            failures.append("route_method_missing_or_invalid")
            continue
        path = str(row.get("path", "")).strip()
        probe = _route_probe_key(raw_method, path)
        if probe not in matched:
            continue
        matched[probe] = True
        probe_label = f"{probe[0]} {probe[1]}"
        status = _as_nonnegative_int(row.get("status_code"))
        body_read = row.get("body_read")
        old_calls = _as_nonnegative_int(row.get("old_handler_calls"))
        if status != 410:
            failures.append(f"route_status_not_410:{probe_label}")
        if body_read is not False:
            failures.append(f"route_body_was_read_or_unmeasured:{probe_label}")
        if old_calls != 0:
            failures.append(f"old_handler_calls_nonzero:{probe_label}")
    for probe, present in matched.items():
        if not present:
            failures.append(f"route_probe_missing:{probe[0]} {probe[1]}")
    return _check(
        "retired-routes",
        failures,
        {
            "probed_route_contracts": sum(matched.values()),
            "required_route_contracts": len(matched),
        },
    )


def _check_old_client(evidence: Mapping[str, Any]) -> dict[str, Any]:
    old = evidence.get("old_client")
    failures: list[str] = []
    if not isinstance(old, Mapping):
        return _check("old-client-negative", ["old_client_evidence_missing"])
    total = _as_nonnegative_int(old.get("requests"))
    upgraded = _as_nonnegative_int(old.get("upgrade_required_requests"))
    successful = _as_nonnegative_int(old.get("successful_requests"))
    status = _as_nonnegative_int(old.get("status_code"))
    if total is None or total == 0:
        failures.append("old_client_requests_missing")
    if status != 426:
        failures.append("old_client_status_not_426")
    if total is not None and upgraded != total:
        failures.append("old_client_upgrade_coverage_below_100")
    if successful is None:
        failures.append("old_client_successful_requests_missing")
    elif successful != 0:
        failures.append("old_client_successful_request_nonzero")
    coverage = old.get("route_family_coverage")
    if isinstance(coverage, bool) or not isinstance(coverage, (int, float)) or coverage < 1:
        failures.append("old_client_route_family_coverage_below_100")
    return _check("old-client-negative", failures)


def _check_egress(evidence: Mapping[str, Any]) -> dict[str, Any]:
    egress = evidence.get("egress")
    failures: list[str] = []
    if not isinstance(egress, Mapping):
        return _check("egress", ["egress_evidence_missing"])
    mode = str(egress.get("mode", "")).strip().lower().replace("_", "-")
    if mode != "default-deny":
        failures.append("egress_not_default_deny")
    records = egress.get("records", [])
    if not isinstance(records, list):
        failures.append("egress_records_invalid")
        records = []
    school_hosts = egress.get("school_personal_hosts", [])
    if not isinstance(school_hosts, list):
        school_hosts = []
    summary = summarize_egress(records, school_hosts=school_hosts)
    explicit_success = _as_nonnegative_int(egress.get("school_personal_success"))
    explicit_unknown = _as_nonnegative_int(egress.get("unknown_necessary_destinations"))
    if explicit_success is None:
        failures.append("school_personal_success_missing")
    if explicit_unknown is None:
        failures.append("unknown_destination_metric_missing")
    if summary["invalid_records"]:
        failures.append("egress_invalid_records")
    if summary["school_personal_success"] != 0 or explicit_success != 0:
        failures.append("school_personal_egress_nonzero")
    if summary["unknown_destination_records"] != 0 or explicit_unknown != 0:
        failures.append("unknown_destination_nonzero")
    return _check(
        "egress",
        failures,
        {
            "mode": mode,
            "total_records": summary["total_records"],
            "allow_records": summary["allow_records"],
            "deny_records": summary["deny_records"],
            "invalid_records": summary["invalid_records"],
            "school_personal_success": summary["school_personal_success"],
            "unknown_destination_records": summary["unknown_destination_records"],
            "issue_counts": summary["issue_counts"],
        },
    )


def _check_historical_zero(evidence: Mapping[str, Any]) -> dict[str, Any]:
    historical = evidence.get("historical_zero")
    failures: list[str] = []
    if not isinstance(historical, Mapping):
        return _check("historical-zero", ["historical_zero_status_missing"])
    status = str(historical.get("status", "")).strip().lower().replace("-", "_")
    if status not in {"verified", "pending_retention_expiry"}:
        failures.append("historical_zero_status_invalid")
    expiry = historical.get("latest_expiry")
    if status == "pending_retention_expiry":
        if not _iso_timestamp(expiry):
            failures.append("historical_zero_expiry_missing_or_invalid")
        else:
            parsed = datetime.fromisoformat(str(expiry).replace("Z", "+00:00"))
            if parsed <= datetime.now(timezone.utc):
                failures.append("historical_zero_expiry_not_future")
    return _check("historical-zero", failures, {"status": status})


def _artifact_members(path: Path) -> Iterable[tuple[str, bytes]]:
    if path.is_dir():
        for child in sorted(path.rglob("*")):
            if child.is_file():
                try:
                    yield child.relative_to(path).as_posix(), child.read_bytes()
                except OSError:
                    continue
        return
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    yield info.filename.replace("\\", "/"), archive.read(info)
        return
    if ".tar" in [suffix.lower() for suffix in path.suffixes] or path.suffix.lower() in {".tgz", ".tbz", ".tbz2"}:
        with tarfile.open(path, mode="r:*") as archive:
            for member in archive.getmembers():
                if member.isfile():
                    stream = archive.extractfile(member)
                    if stream is not None:
                        yield member.name.replace("\\", "/"), stream.read()
        return
    raise ValueError("unsupported_artifact_format")


def _artifact_check(artifact: Path | None) -> dict[str, Any]:
    if artifact is None:
        return _check("release-artifact", ["artifact_missing"])
    if not artifact.exists():
        return _check("release-artifact", ["artifact_not_found"])
    failures: list[str] = []
    findings: list[dict[str, Any]] = []
    file_count = 0
    try:
        for name, content in _artifact_members(artifact):
            file_count += 1
            normalized = name.lstrip("./")
            lower_name = PurePosixPath(normalized).name.lower()
            if "remoteacademicgateway" in lower_name or "legacycampusregistrationverifier" in lower_name:
                findings.append({"path": normalized, "rule": "forbidden_artifact_filename"})
            # Search bytes as well as decoded text so a compiled binary cannot hide
            # a route or gateway behind a non-UTF8 section.
            decoded = content.decode("utf-8", errors="replace")
            for rule, pattern in FORBIDDEN_ARTIFACT_PATTERNS.items():
                if pattern.search(decoded):
                    findings.append({"path": normalized, "rule": rule})
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile):
        return _check("release-artifact", ["artifact_unreadable"])
    if findings:
        failures.append("forbidden_release_artifact_content")
    return _check("release-artifact", failures, {"file_count": file_count, "finding_count": len(findings), "findings": findings})


def verify_evidence(evidence: Mapping[str, Any], artifact: str | Path | None = None) -> dict[str, Any]:
    """验证一份 PR13 证据并返回结构化、脱敏结果。"""

    checks = [
        _check_metadata(evidence),
        _check_observation_window(evidence),
        _check_zero_metrics(evidence),
        _check_canary(evidence),
        _check_retired_routes(evidence),
        _check_old_client(evidence),
        _check_egress(evidence),
        _check_historical_zero(evidence),
        _artifact_check(Path(artifact).resolve() if artifact is not None else None),
    ]
    if _contains_sensitive_key(evidence):
        checks.append(_check("evidence-redaction", ["sensitive_key_present"]))
    else:
        checks.append(_check("evidence-redaction", []))
    failed = [item for item in checks if item["status"] == "fail"]
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "fail" if failed else "pass",
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "checks": len(checks),
            "failed_checks": len(failed),
            "finding_count": sum(len(item.get("findings", [])) for item in checks),
        },
        "checks": checks,
    }


def _check_observation_window(evidence: Mapping[str, Any]) -> dict[str, Any]:
    """PR13 最终声明至少覆盖连续七天的 Canary/egress 观察。"""

    raw = evidence.get("observation_window_hours")
    value = _as_nonnegative_int(raw)
    failures: list[str] = []
    if value is None:
        failures.append("observation_window_missing_or_invalid")
    elif value < 7 * 24:
        failures.append("observation_window_below_168_hours")
    return _check("observation-window", failures, {"hours": value} if value is not None else None)


def _dry_run() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "read_only": True,
        "required_zero_metrics": list(ZERO_METRICS),
        "required_canary_metrics": list(CANARY_METRICS),
        "required_observation_window_hours": 168,
        "retired_route_probes": [
            {"method": method, "path": path} for method, path in RETIRED_ROUTE_PROBES
        ],
        "required_roles": list(REQUIRED_ROLES),
        "egress_mode": "default-deny",
        "historical_zero_status": ["verified", "pending_retention_expiry"],
        "artifact_scan_rules": sorted(FORBIDDEN_ARTIFACT_PATTERNS),
    }


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PR13 四个零与学校权限最终验收门禁")
    parser.add_argument("--evidence", type=Path, help="受控聚合证据 JSON")
    parser.add_argument("--artifact", type=Path, help="Release 目录、ZIP 或 TAR")
    parser.add_argument("--pretty", action="store_true", help="缩进 JSON")
    parser.add_argument("--dry-run", action="store_true", help="只输出字段契约，不读取证据或发布物")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.dry_run:
        print(json.dumps(_dry_run(), ensure_ascii=False, indent=2 if args.pretty else None))
        return 0
    if args.evidence is None:
        print("zero_authority_verify: evidence_missing", file=sys.stderr)
        return 2
    try:
        raw = args.evidence.read_text(encoding="utf-8")
        evidence = json.loads(raw)
        if not isinstance(evidence, Mapping):
            raise ValueError("evidence_not_object")
        report = verify_evidence(evidence, args.artifact)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        # 不回显路径、底层异常或输入内容，避免受控证据意外进入普通日志。
        print("zero_authority_verify: evidence_unreadable", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=True))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
