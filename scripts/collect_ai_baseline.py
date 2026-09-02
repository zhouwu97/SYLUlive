#!/usr/bin/env python3
"""采集并校验 T00 基线证据。

脚本只读取调用者明确指定的本地文件和只读命令，不负责 SSH、HTTP、数据库
写入或生产配置变更。默认 dry-run；写出 JSON/Markdown 报告必须显式确认。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from collections.abc import Iterable, Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "t00-baseline/v1"
EVIDENCE_TYPES = ("fixture", "staging", "online")
TIMING_FIELDS = (
    "case_id",
    "q_hmac",
    "t_accept_ms",
    "t_first_status_ms",
    "t_first_delta_ms",
    "t_complete_ms",
    "tool_hit",
    "cancelled",
    "degraded",
)
TIME_FIELDS = (
    "t_accept_ms",
    "t_first_status_ms",
    "t_first_delta_ms",
    "t_complete_ms",
)
OPTIONAL_TIME_FIELDS = {"t_first_delta_ms", "t_complete_ms"}
FLAG_KEYS = (
    "AI_POLICY_RAG_ENABLED",
    "AI_LANGCHAIN_RAG_ENABLED",
    "AI_LEGACY_RAG_ENABLED",
    "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT",
    "AI_AGENT_ENABLED",
    "RAG_RERANKER_ENABLED",
    "RAG_RETRIEVER_ENABLED",
    "RAG_GENERATION_ENABLED",
    "RAG_SHADOW_INDEX_ENABLED",
    "RAG_ALLOW_LANGSMITH",
)
BOOL_FLAGS = {
    key for key in FLAG_KEYS if key not in {"AI_LANGCHAIN_RAG_ROLLOUT_PERCENT"}
}
MCP_FIELDS = ("enabled", "protocol", "healthy", "version", "status")
KNOWLEDGE_FIELDS = (
    "version",
    "schema_version",
    "embedding_model",
    "embedding_dimension",
    "sha256",
    "published_at",
    "status",
)
SERVICE_NAME_RE = re.compile(r"^[A-Za-z0-9_.@:-]{1,160}$")
CASE_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,80}$")
HMAC_RE = re.compile(r"^[0-9a-f]{24}$")
FORBIDDEN_KEY_RE = re.compile(
    r"(?:question|answer|prompt|cookie|jwt|password|passwd|secret|token|dsn|"
    r"authorization|history|retrieval|query|response|content|credential)",
    re.IGNORECASE,
)
FORBIDDEN_VALUE_RE = re.compile(
    r"(?:^|\s)(?:Bearer\s+\S+|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|"
    r"(?:postgres(?:ql)?|mysql)://\S+|-----BEGIN\s+[^-]+-----)",
    re.IGNORECASE,
)


class BaselineError(ValueError):
    """输入不符合 T00 脱敏证据契约。"""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _safe_text(value: Any, *, field: str, max_length: int = 240) -> str:
    if not isinstance(value, str) or not value or len(value) > max_length:
        raise BaselineError(f"{field} 必须是长度不超过 {max_length} 的非空文本")
    if any(ord(character) < 32 for character in value) or FORBIDDEN_VALUE_RE.search(
        value
    ):
        raise BaselineError(f"{field} 含有禁止写入报告的内容")
    return value


def _parse_env_value(key: str, raw: str) -> Any:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    if key in BOOL_FLAGS:
        normalized = value.lower()
        if normalized in {"true", "1", "yes", "on"}:
            return True
        if normalized in {"false", "0", "no", "off"}:
            return False
        raise BaselineError(f"环境开关 {key} 必须是布尔值")
    if key == "AI_LANGCHAIN_RAG_ROLLOUT_PERCENT":
        try:
            percent = int(value)
        except ValueError as exc:
            raise BaselineError(f"环境开关 {key} 必须是整数") from exc
        if not 0 <= percent <= 100:
            raise BaselineError(f"环境开关 {key} 必须在 0 到 100 之间")
        return percent
    return _safe_text(value, field=key)


def parse_env_file(path: Path | None) -> dict[str, Any]:
    """只读取白名单开关，永远不把未知环境变量复制到报告。"""

    if path is None:
        return {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise BaselineError(f"无法读取环境文件: {path}") from exc
    values: dict[str, Any] = {}
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        key = key.strip()
        if key not in FLAG_KEYS:
            continue
        try:
            values[key] = _parse_env_value(key, raw_value)
        except BaselineError as exc:
            raise BaselineError(f"{path}:{line_number}: {exc}") from exc
    return values


def collect_file_metadata(path: Path) -> dict[str, Any]:
    """读取文件元数据和 SHA-256，不读取或保存文件正文。"""

    try:
        stat = path.stat()
    except OSError as exc:
        raise BaselineError(f"无法读取文件: {path}") from exc
    if not path.is_file():
        raise BaselineError(f"部署摘要目标不是普通文件: {path}")
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise BaselineError(f"无法计算文件摘要: {path}") from exc
    modified = datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(
        timespec="seconds"
    )
    return {
        "path": path.as_posix(),
        "size_bytes": stat.st_size,
        "mtime_utc": modified,
        "sha256": digest.hexdigest(),
    }


def _git_value(repo: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=repo,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def collect_repository(repo: Path) -> dict[str, Any]:
    """采集分支和提交，失败时用明确的未采集状态表示。"""

    return {
        "path": repo.resolve().as_posix(),
        "branch": _git_value(repo, "branch", "--show-current"),
        "commit": _git_value(repo, "rev-parse", "HEAD"),
    }


def _load_object(path: Path, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BaselineError(f"{label} 不是有效 UTF-8 JSON 对象: {path}") from exc
    if not isinstance(value, Mapping):
        raise BaselineError(f"{label} 顶层必须是 JSON 对象")
    return value


def _optional_scalar(value: Any, *, field: str) -> Any:
    if value is None:
        return None
    if isinstance(value, str) and not value.strip():
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value
    return _safe_text(value, field=field)


def parse_mcp_status(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    source = _load_object(path, "MCP 状态")
    result: dict[str, Any] = {}
    for field in MCP_FIELDS:
        if field in source:
            value = source[field]
            if field in {"enabled", "healthy"} and not isinstance(value, bool):
                raise BaselineError(f"MCP 字段 {field} 必须是布尔值")
            result[field] = _optional_scalar(value, field=f"mcp.{field}")
    return result


def parse_knowledge_manifest(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    source = _load_object(path, "知识库清单")
    result: dict[str, Any] = {}
    for field in KNOWLEDGE_FIELDS:
        if field not in source:
            continue
        value = source[field]
        if field in {"embedding_dimension"}:
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise BaselineError("知识库 embedding_dimension 必须是正整数")
            result[field] = value
        elif field == "sha256":
            text = _safe_text(value, field="knowledge.sha256", max_length=128)
            if not re.fullmatch(r"[0-9a-fA-F]{64}", text):
                raise BaselineError("知识库 sha256 必须是 64 位十六进制摘要")
            result[field] = text.lower()
        else:
            result[field] = _optional_scalar(value, field=f"knowledge.{field}")
    return result


def collect_systemd_service(service: str) -> dict[str, Any]:
    """只执行 systemctl show；Windows 或缺少 systemd 时不报成服务故障。"""

    if not SERVICE_NAME_RE.fullmatch(service):
        raise BaselineError(f"systemd 服务名不安全: {service}")
    result: dict[str, Any] = {"service": service}
    systemctl = shutil.which("systemctl")
    if systemctl is None:
        result["status"] = "not_available"
        return result
    try:
        completed = subprocess.run(
            [
                systemctl,
                "show",
                service,
                "--no-page",
                "--property=ActiveState,SubState,MainPID,ExecMainStartTimestamp",
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=8,
        )
    except (OSError, subprocess.TimeoutExpired):
        result["status"] = "unavailable"
        return result
    if completed.returncode != 0:
        result["status"] = "unavailable"
        return result
    for line in completed.stdout.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key == "MainPID":
            try:
                result[key] = int(value)
            except ValueError:
                result[key] = None
        elif key in {"ActiveState", "SubState", "ExecMainStartTimestamp"}:
            result[key] = _optional_scalar(value, field=f"systemd.{key}")
    result["status"] = "collected"
    return result


def _validate_timing(record: Mapping[str, Any], line_number: int) -> dict[str, Any]:
    expected = set(TIMING_FIELDS)
    actual = set(record)
    missing = expected - actual
    extra = actual - expected
    if missing or extra:
        detail = []
        if missing:
            detail.append(f"缺少 {sorted(missing)}")
        if extra:
            detail.append(f"多出 {sorted(extra)}")
        raise BaselineError(
            f"JSONL 第 {line_number} 行字段不符合契约: {'; '.join(detail)}"
        )
    case_id = record["case_id"]
    if not isinstance(case_id, str) or not CASE_ID_RE.fullmatch(case_id):
        raise BaselineError(f"JSONL 第 {line_number} 行 case_id 不安全")
    q_hmac = record["q_hmac"]
    if not isinstance(q_hmac, str) or not HMAC_RE.fullmatch(q_hmac):
        raise BaselineError(
            f"JSONL 第 {line_number} 行 q_hmac 必须是 24 位小写十六进制"
        )
    normalized: dict[str, Any] = {"case_id": case_id, "q_hmac": q_hmac}
    for field in TIME_FIELDS:
        value = record[field]
        if value is None and field in OPTIONAL_TIME_FIELDS:
            normalized[field] = None
            continue
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise BaselineError(f"JSONL 第 {line_number} 行 {field} 必须是非负整数")
        normalized[field] = value
    for field in ("tool_hit", "cancelled"):
        if not isinstance(record[field], bool):
            raise BaselineError(f"JSONL 第 {line_number} 行 {field} 必须是布尔值")
        normalized[field] = record[field]
    degraded = record["degraded"]
    if degraded is not None and (
        not isinstance(degraded, str) or not CASE_ID_RE.fullmatch(degraded)
    ):
        raise BaselineError(f"JSONL 第 {line_number} 行 degraded 必须是短类型标识")
    normalized["degraded"] = degraded
    return normalized


def parse_timings(path: Path | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise BaselineError(f"无法读取延迟 JSONL: {path}") from exc
    records: list[dict[str, Any]] = []
    seen_case_ids: set[str] = set()
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise BaselineError(f"JSONL 第 {line_number} 行不是有效 JSON") from exc
        if not isinstance(value, Mapping):
            raise BaselineError(f"JSONL 第 {line_number} 行必须是对象")
        normalized = _validate_timing(value, line_number)
        case_id = normalized["case_id"]
        if case_id in seen_case_ids:
            raise BaselineError(f"JSONL 第 {line_number} 行 case_id 重复: {case_id}")
        seen_case_ids.add(case_id)
        previous_time: int | None = None
        for field in TIME_FIELDS:
            current_time = normalized[field]
            if current_time is None:
                continue
            if previous_time is not None and current_time < previous_time:
                raise BaselineError(
                    f"JSONL 第 {line_number} 行时间点倒序: {field}={current_time}"
                )
            previous_time = current_time
        records.append(normalized)
    return records


def _assert_no_sensitive_data(value: Any, location: str = "root") -> None:
    """递归检查最终报告，防止白名单扩展时意外带出敏感字段。"""

    if isinstance(value, Mapping):
        for key, child in value.items():
            key_text = str(key)
            if FORBIDDEN_KEY_RE.search(key_text):
                raise BaselineError(
                    f"报告字段 {location}.{key_text} 命中敏感字段黑名单"
                )
            _assert_no_sensitive_data(child, f"{location}.{key_text}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _assert_no_sensitive_data(child, f"{location}[{index}]")
    elif isinstance(value, str) and FORBIDDEN_VALUE_RE.search(value):
        raise BaselineError(f"报告字段 {location} 命中敏感值黑名单")


def _missing_items(
    binaries: list[dict[str, Any]],
    runtime_flags: Mapping[str, Any],
    mcp: Mapping[str, Any] | None,
    knowledge: Mapping[str, Any] | None,
    timings: list[dict[str, Any]],
) -> list[str]:
    missing: list[str] = []
    if not binaries:
        missing.append("deployment.binary")
    missing_flags = sorted(set(FLAG_KEYS) - set(runtime_flags))
    if missing_flags:
        missing.append("deployment.runtime_flags:" + ",".join(missing_flags))
    if mcp is None:
        missing.append("deployment.mcp")
    if knowledge is None:
        missing.append("deployment.knowledge")
    if not timings:
        missing.append("timings")
    return missing


def build_bundle(
    *,
    repo: Path,
    evidence_type: str,
    binaries: Iterable[Path],
    runtime_env: Path | None,
    defaults_env: Path | None,
    services: Iterable[str],
    mcp_status: Path | None,
    knowledge_manifest: Path | None,
    timings_file: Path | None,
) -> dict[str, Any]:
    if evidence_type not in EVIDENCE_TYPES:
        raise BaselineError(f"证据类型必须是: {', '.join(EVIDENCE_TYPES)}")
    binary_metadata = [collect_file_metadata(path) for path in binaries]
    runtime_flags = parse_env_file(runtime_env)
    defaults = parse_env_file(defaults_env)
    systemd = [collect_systemd_service(service) for service in services]
    mcp = parse_mcp_status(mcp_status)
    knowledge = parse_knowledge_manifest(knowledge_manifest)
    timings = parse_timings(timings_file)
    bundle: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": _utc_now(),
        "evidence_type": evidence_type,
        "writes_performed": False,
        "collection_mode": "local_read_only_inputs",
        "repository": collect_repository(repo),
        "deployment": {
            "binaries": binary_metadata,
            "flags": {
                "code_defaults": defaults,
                "runtime_values": runtime_flags,
            },
            "systemd": systemd,
            "mcp": mcp,
            "knowledge": knowledge,
        },
        "timings": timings,
    }
    bundle["missing"] = _missing_items(
        binary_metadata, runtime_flags, mcp, knowledge, timings
    )
    _assert_no_sensitive_data(bundle)
    return bundle


def _display(value: Any) -> str:
    if value is None:
        return "未采集"
    if isinstance(value, bool):
        return "是" if value else "否"
    return str(value)


def _markdown_cell(value: Any) -> str:
    """限制报告值在单个 Markdown 表格单元格内。"""

    return _display(value).replace("|", "\\|").replace("`", "\\`").replace("\n", " ")


def render_markdown(bundle: Mapping[str, Any]) -> str:
    """用固定字段生成报告，避免把输入 JSON 原样复制到 Markdown。"""

    repository = bundle.get("repository", {})
    deployment = bundle.get("deployment", {})
    flags = deployment.get("flags", {})
    lines = [
        "# 优化基线报告（T00）",
        "",
        f"- 生成时间（UTC）：{_display(bundle.get('generated_at'))}",
        f"- 证据类型：`{_display(bundle.get('evidence_type'))}`",
        f"- 分支：`{_display(repository.get('branch'))}`",
        f"- 提交 SHA：`{_display(repository.get('commit'))}`",
        f"- 采集模式：`{_display(bundle.get('collection_mode'))}`",
        "",
        "## 部署事实",
        "",
        "### 二进制摘要",
        "",
        "| 路径 | 大小（字节） | mtime（UTC） | SHA-256 |",
        "| --- | ---: | --- | --- |",
    ]
    binaries = deployment.get("binaries") or []
    if binaries:
        for item in binaries:
            lines.append(
                "| `{path}` | {size} | {mtime} | `{sha}` |".format(
                    path=_markdown_cell(item.get("path")),
                    size=_markdown_cell(item.get("size_bytes")),
                    mtime=_markdown_cell(item.get("mtime_utc")),
                    sha=_markdown_cell(item.get("sha256")),
                )
            )
    else:
        lines.append("| 未采集 | - | - | - |")
    lines.extend(
        [
            "",
            "### AI 开关",
            "",
            "| 开关 | 代码默认值 | 运行时真值 |",
            "| --- | --- | --- |",
        ]
    )
    defaults = flags.get("code_defaults", {}) if isinstance(flags, Mapping) else {}
    runtime = flags.get("runtime_values", {}) if isinstance(flags, Mapping) else {}
    for key in FLAG_KEYS:
        lines.append(
            f"| `{key}` | {_markdown_cell(defaults.get(key))} | "
            f"{_markdown_cell(runtime.get(key))} |"
        )
    lines.extend(["", "### systemd / MCP / 知识库", ""])
    lines.append(f"- systemd：`{_markdown_cell(deployment.get('systemd'))}`")
    lines.append(f"- 外部 MCP：`{_markdown_cell(deployment.get('mcp'))}`")
    lines.append(f"- 已发布知识库：`{_markdown_cell(deployment.get('knowledge'))}`")
    lines.extend(
        [
            "",
            "## 延迟基线（脱敏）",
            "",
            "| 用例 ID | 问题 HMAC | 首状态（ms） | 首增量（ms） | 完成（ms） | 工具 | 取消 | 降级 |",
            "| --- | --- | ---: | ---: | ---: | --- | --- | --- |",
        ]
    )
    timings = bundle.get("timings") or []
    if timings:
        for item in timings:
            lines.append(
                "| {case} | `{hmac}` | {status} | {delta} | {complete} | {tool} | {cancel} | {degraded} |".format(
                    case=_markdown_cell(item.get("case_id")),
                    hmac=_markdown_cell(item.get("q_hmac")),
                    status=_markdown_cell(item.get("t_first_status_ms")),
                    delta=_markdown_cell(item.get("t_first_delta_ms")),
                    complete=_markdown_cell(item.get("t_complete_ms")),
                    tool=_markdown_cell(item.get("tool_hit")),
                    cancel=_markdown_cell(item.get("cancelled")),
                    degraded=_markdown_cell(item.get("degraded")),
                )
            )
    else:
        lines.append("| 未采集 | - | - | - | - | - | - | - |")
    lines.extend(["", "## 缺失项与门禁", ""])
    missing = bundle.get("missing") or []
    if missing:
        lines.extend(f"- `待补：{item}`" for item in missing)
    else:
        lines.append("- T00 输入项齐备，仍需人工复核证据来源与授权记录。")
    lines.extend(
        [
            "",
            "> 本报告只允许保存用例 ID、24 位 HMAC 和类型化结果；fixture/staging/线上证据不得互相替代。",
            "",
        ]
    )
    return "\n".join(lines)


def _write_text(path: Path, content: str, *, overwrite: bool) -> None:
    if path.exists() and not overwrite:
        raise BaselineError(f"输出文件已存在，需显式提供 --overwrite: {path}")
    if path.exists() and not path.is_file():
        raise BaselineError(f"输出目标不是普通文件: {path}")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")
    except OSError as exc:
        raise BaselineError(f"无法写入输出文件: {path}") from exc


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="采集 T00 脱敏 AI 基线证据")
    parser.add_argument("--evidence-type", choices=EVIDENCE_TYPES, default="fixture")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--binary", action="append", type=Path, default=[])
    parser.add_argument("--runtime-env", type=Path)
    parser.add_argument("--defaults-env", type=Path)
    parser.add_argument("--systemd-service", action="append", default=[])
    parser.add_argument("--mcp-status", type=Path)
    parser.add_argument("--knowledge-manifest", type=Path)
    parser.add_argument("--timings-jsonl", type=Path)
    parser.add_argument("--output", type=Path, help="执行模式下写出的 JSON 报告")
    parser.add_argument(
        "--markdown-output", type=Path, help="执行模式下写出的 Markdown 报告"
    )
    parser.add_argument("--execute", action="store_true", help="显式写出报告")
    parser.add_argument("--confirm", default="", help="写出确认短语")
    parser.add_argument("--overwrite", action="store_true", help="允许覆盖已有报告")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        bundle = build_bundle(
            repo=args.repo,
            evidence_type=args.evidence_type,
            binaries=args.binary,
            runtime_env=args.runtime_env,
            defaults_env=args.defaults_env,
            services=args.systemd_service,
            mcp_status=args.mcp_status,
            knowledge_manifest=args.knowledge_manifest,
            timings_file=args.timings_jsonl,
        )
        if not args.execute:
            preview = {
                "schema_version": "t00-baseline/plan/v1",
                "evidence_type": args.evidence_type,
                "writes_performed": False,
                "collection_mode": "local_read_only_inputs",
                "would_collect": [
                    "repository",
                    "binary_sha256",
                    "allowlisted_runtime_flags",
                    "systemd_show",
                    "mcp_allowlist",
                    "knowledge_allowlist",
                    "typed_timing_jsonl",
                ],
                "missing": bundle["missing"],
                "write_hint": "--execute --confirm WRITE:T00-BASELINE --output <path>",
            }
            print(json.dumps(preview, ensure_ascii=False, indent=2))
            return 0
        expected_confirmation = (
            "WRITE:T00-ONLINE-READONLY"
            if args.evidence_type == "online"
            else "WRITE:T00-BASELINE"
        )
        if args.confirm != expected_confirmation:
            raise BaselineError(
                f"{args.evidence_type} 证据写出必须提供确认短语 {expected_confirmation}"
            )
        if args.output is None and args.markdown_output is None:
            raise BaselineError("执行模式至少需要 --output 或 --markdown-output")
        bundle["writes_performed"] = True
        _assert_no_sensitive_data(bundle)
        if args.output is not None:
            _write_text(
                args.output,
                json.dumps(bundle, ensure_ascii=False, indent=2) + "\n",
                overwrite=args.overwrite,
            )
        if args.markdown_output is not None:
            _write_text(
                args.markdown_output,
                render_markdown(bundle),
                overwrite=args.overwrite,
            )
        print(
            json.dumps(
                {
                    "schema_version": SCHEMA_VERSION,
                    "evidence_type": args.evidence_type,
                    "writes_performed": True,
                    "output": args.output.as_posix() if args.output else None,
                    "markdown_output": (
                        args.markdown_output.as_posix()
                        if args.markdown_output
                        else None
                    ),
                    "missing": bundle["missing"],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    except BaselineError as exc:
        print(f"T00 基线采集失败: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
