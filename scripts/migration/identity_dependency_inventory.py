#!/usr/bin/env python3
"""账号身份迁移的静态依赖盘点。

脚本只输出相对文件路径、依赖类别和命中计数，不输出命中行、字段值、邮箱、学号、
请求体或其他原始标识。结果用于 PR2 预检、PR3 expand/backfill 和 PR12 drop 的人工
复核，不把静态命中数误认为生产数据统计。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence
from zoneinfo import ZoneInfo


SCHEMA_VERSION = "identity-dependency-inventory.v1"
SHANGHAI = ZoneInfo("Asia/Shanghai")

# 只扫描可能包含源码、SQL 或配置的文本文件；二进制和构建产物不进入盘点。
TEXT_SUFFIXES = {
    ".c",
    ".cc",
    ".conf",
    ".cpp",
    ".dart",
    ".go",
    ".ini",
    ".js",
    ".json",
    ".md",
    ".py",
    ".sh",
    ".sql",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".yaml",
    ".yml",
}
EXCLUDED_DIRS = {
    ".git",
    ".dart_tool",
    ".pytest_cache",
    ".venv",
    "__pycache__",
    "build",
    "dist",
    "node_modules",
    "output",
    "private-probe-output",
    "uploads",
    "vendor",
}
SCAN_ROOTS = ("server", "python-edu-service", "client")


@dataclass(frozen=True)
class DependencyRule:
    """一个依赖项的名称和源码匹配规则。"""

    name: str
    patterns: tuple[re.Pattern[str], ...]


def _patterns(*values: str) -> tuple[re.Pattern[str], ...]:
    return tuple(re.compile(value, re.IGNORECASE) for value in values)


# 规则名称保持稳定，便于不同快照之间比较。规则只用于计数，不把匹配文本写入报告。
DEPENDENCY_RULES: tuple[DependencyRule, ...] = (
    DependencyRule(
        "users.student_id",
        _patterns(
            r"\busers?\s*\.\s*student[_-]?id\b",
            r"\bstudent[_-]?id\b",
            r"\bstudentId\b",
            r"\bStudentID\b",
            r"学号",
        ),
    ),
    DependencyRule(
        "users.student_verified_at",
        _patterns(r"\busers?\s*\.\s*student_verified_at\b", r"\bstudent_verified_at\b"),
    ),
    DependencyRule(
        "users.email",
        _patterns(r"\busers?\s*\.\s*email\b", r"\bemail\b", r"['\"]email['\"]"),
    ),
    DependencyRule(
        "users.email_verified_at",
        _patterns(r"\busers?\s*\.\s*email_verified_at\b", r"\bemail_verified_at\b"),
    ),
    DependencyRule("users.qq", _patterns(r"\busers?\s*\.\s*qq\b", r"\bqq\b", r"QQ")),
    DependencyRule(
        "Edu*",
        _patterns(
            r"\bEdu[A-Za-z0-9_]*\b",
            r"\bedu_[a-z0-9_]+\b",
            r"\bedu[-_]service\b",
            r"/api/edu(?:/|\b)",
        ),
    ),
    DependencyRule(
        "legacy_auth_api",
        _patterns(
            r"/api/(?:login|register|password)(?:[_/-](?:edu|email))?\b",
            r"\b(?:login_edu|register_with_edu)\b",
            r"/auth/(?:login|register|password)\b",
        ),
    ),
    DependencyRule(
        "client_auth_request_fields",
        _patterns(
            r"['\"]?(?:student_id|studentId|edu_password|eduPassword|email|password)['\"]?\s*:",
            r"\b(?:studentId|eduPassword|loginEdu|registerWithEdu)\b",
        ),
    ),
)

STUDENT_TOKEN = re.compile(r"\bstudent[_-]?id\b|\bstudentId\b|\bStudentID\b|学号", re.IGNORECASE)

# 文件路径和同一行的语义词用于识别计划要求单独复核的 StudentID 表面。
SURFACE_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("student_id.admin_surface", ("admin", "administrator", "管理员", "后台")),
    ("student_id.search_surface", ("search", "搜索", "query", "查询")),
    ("student_id.posts_surface", ("post", "帖子", "feed", "动态")),
    ("student_id.messages_surface", ("message", "消息", "chat", "通知")),
    ("student_id.privacy_export_surface", ("privacy", "隐私", "export", "导出")),
    ("student_id.logout_surface", ("logout", "signout", "注销", "退出")),
)

OPERATION_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "index_constraint",
        re.compile(
            r"\b(?:create|drop|alter)\s+(?:unique\s+)?(?:partial\s+)?(?:index|table|column|constraint)\b"
            r"|\b(?:unique\s+index|constraint|gorm:\"[^\"]*(?:index|unique))\b"
            r"|\b(?:primary\s+key|foreign\s+key)\b",
            re.IGNORECASE,
        ),
    ),
    (
        "response_output",
        re.compile(
            r"\b(?:json\.dumps|json\.marshal|marshaljson|serialize|serializer|response|render|writejson)\b"
            r"|\b(?:return|respond|send|write)\b[^\n]*(?:json|http|body|payload|export|csv|map\s*\[)"
            r"|json\s*:\s*|json=",
            re.IGNORECASE,
        ),
    ),
    (
        "write",
        re.compile(
            r"\b(?:insert|update|delete|upsert|create|save|set|assign|append|put|post|patch)\b"
            r"|\b(?:firstorcreate|savechanges|execute|exec)\b"
            r"|(?:=\s*[^=]|:=)\s*[^\n]*(?:student|email|qq|edu)",
            re.IGNORECASE,
        ),
    ),
    (
        "read",
        re.compile(
            r"\b(?:select|query|find|first|where|join|fetch|get|load|read|scan|filter|lookup|count)\b"
            r"|\b(?:request|params|args|queryparams)\b",
            re.IGNORECASE,
        ),
    ),
)


def _script_sha256() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def _base_sha(root: Path) -> str:
    try:
        value = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return "unavailable"
    return value if re.fullmatch(r"[0-9a-f]{7,64}", value) else "unavailable"


def _is_text(path: Path) -> bool:
    if path.suffix.lower() in TEXT_SUFFIXES or path.name in {"Dockerfile", ".dockerignore"}:
        return True
    try:
        sample = path.read_bytes()[:4096]
    except OSError:
        return False
    return b"\x00" not in sample


def _iter_source_files(root: Path) -> Iterator[Path]:
    """遍历计划范围，显式排除构建物和缓存。"""

    for source_root_name in SCAN_ROOTS:
        source_root = root / source_root_name
        if not source_root.exists():
            continue
        for path in sorted(source_root.rglob("*")):
            if not path.is_file() or not _is_text(path):
                continue
            try:
                relative_parts = path.relative_to(source_root).parts
            except ValueError:
                continue
            if any(part in EXCLUDED_DIRS for part in relative_parts):
                continue
            yield path


def _is_fixture(path: Path) -> bool:
    parts = {part.lower() for part in path.parts}
    name = path.name.lower()
    if parts.intersection(
        {
            "test",
            "tests",
            "testdata",
            "fixtures",
            "fixture",
            "mocks",
            "mock",
            "goldens",
            "tools",
            "probes",
            "probe",
        }
    ):
        return True
    return (
        name.startswith("test_")
        or name.startswith("test-")
        or name.endswith("_test.go")
        or name.endswith("_test.py")
        or name.endswith("_test.dart")
        or ".test." in name
        or "fixture" in name
        or "mock" in name
    )


def _relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def _surface_names(path: Path, line: str) -> list[str]:
    haystack = f"{path.as_posix()}\n{line}".lower()
    if not STUDENT_TOKEN.search(line):
        return []
    return [name for name, terms in SURFACE_RULES if any(term.lower() in haystack for term in terms)]


def _classify(path: Path, line: str) -> str:
    if _is_fixture(path):
        return "test_fixture"
    for category, pattern in OPERATION_RULES:
        if pattern.search(line):
            return category
    return "read"


def _matching_count(patterns: Iterable[re.Pattern[str]], line: str) -> int:
    return sum(len(tuple(pattern.finditer(line))) for pattern in patterns)


def build_inventory(root: str | Path) -> dict[str, object]:
    """扫描源码并返回不含命中原文的聚合结果。"""

    repository = Path(root).resolve()
    counts: defaultdict[tuple[str, str, str], int] = defaultdict(int)
    files_scanned = 0
    files_with_hits: set[str] = set()
    total_hits = 0
    for path in _iter_source_files(repository):
        files_scanned += 1
        relative = _relative(path, repository)
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            category = _classify(path, line)
            matched_dependencies: list[tuple[str, int]] = []
            for rule in DEPENDENCY_RULES:
                hit_count = _matching_count(rule.patterns, line)
                if hit_count:
                    matched_dependencies.append((rule.name, hit_count))
            for name, hit_count in matched_dependencies:
                counts[(name, category, relative)] += hit_count
                total_hits += hit_count
            for surface_name in _surface_names(path, line):
                counts[(surface_name, category, relative)] += 1
                total_hits += 1
            if matched_dependencies or _surface_names(path, line):
                files_with_hits.add(relative)

    rows = [
        {"dependency": dependency, "category": category, "path": path, "hit_count": hit_count}
        for (dependency, category, path), hit_count in sorted(counts.items())
    ]
    dependency_totals: defaultdict[str, int] = defaultdict(int)
    category_totals: defaultdict[str, int] = defaultdict(int)
    for row in rows:
        dependency_totals[str(row["dependency"])] += int(row["hit_count"])
        category_totals[str(row["category"])] += int(row["hit_count"])

    return {
        "schema_version": SCHEMA_VERSION,
        "read_only": True,
        "generated_at": datetime.now(SHANGHAI).isoformat(timespec="seconds"),
        "base_sha": _base_sha(repository),
        "script_sha256": _script_sha256(),
        "scope": list(SCAN_ROOTS),
        "summary": {
            "files_scanned": files_scanned,
            "files_with_hits": len(files_with_hits),
            "hit_count": total_hits,
            "dependency_totals": dict(sorted(dependency_totals.items())),
            "category_totals": dict(sorted(category_totals.items())),
        },
        # rows 只含相对路径、稳定类别和数字，不含源码片段。
        "rows": rows,
    }


def _markdown(report: Mapping[str, object]) -> str:
    summary = report["summary"]
    assert isinstance(summary, Mapping)
    lines = [
        "# Identity Dependency Inventory（脱敏聚合）",
        "",
        "> 仅记录源码路径、依赖类别和命中计数；不记录命中行、Email、StudentID 或字段值。",
        "",
        f"- 生成时间（Asia/Shanghai）：`{report['generated_at']}`",
        f"- Base SHA：`{report['base_sha']}`",
        f"- 脚本 SHA-256：`{report['script_sha256']}`",
        f"- 扫描范围：`{', '.join(str(value) for value in report['scope'])}`",
        f"- 文件数：`{summary['files_scanned']}`；有命中文件：`{summary['files_with_hits']}`；命中数：`{summary['hit_count']}`",
        "",
        "| 依赖 | 类别 | 文件 | 命中数 |",
        "| --- | --- | --- | ---: |",
    ]
    for row in report["rows"]:  # type: ignore[index]
        lines.append(
            f"| `{row['dependency']}` | `{row['category']}` | `{row['path']}` | {row['hit_count']} |"
        )
    lines.extend(
        [
            "",
            "类别定义：`read`、`write`、`response_output`、`index_constraint`、`test_fixture`。",
            "静态命中仅用于人工复核，不等同于生产数据数量或上线验收结论。",
        ]
    )
    return "\n".join(lines) + "\n"


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="账号身份迁移静态依赖盘点")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help="仓库根目录")
    parser.add_argument("--output", type=Path, help="输出 JSON/Markdown 文件，不指定则输出到标准输出")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--pretty", action="store_true", help="JSON 使用缩进格式")
    parser.add_argument("--dry-run", action="store_true", help="只输出扫描范围和规则，不读取源码")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.dry_run:
        dry_run = {
            "schema_version": SCHEMA_VERSION,
            "read_only": True,
            "scope": list(SCAN_ROOTS),
            "categories": ["read", "write", "response_output", "index_constraint", "test_fixture"],
            "dependencies": [rule.name for rule in DEPENDENCY_RULES]
            + [name for name, _ in SURFACE_RULES],
            "script_sha256": _script_sha256(),
        }
        content = json.dumps(dry_run, ensure_ascii=False, indent=2 if args.pretty else None) + "\n"
    else:
        try:
            report = build_inventory(args.root)
            content = _markdown(report) if args.format == "markdown" else json.dumps(
                report, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=True
            ) + "\n"
        except Exception:
            # 不回显路径、源码或底层异常，避免静态扫描错误意外带出标识。
            print("身份依赖盘点失败：无法读取扫描范围", file=sys.stderr)
            return 2
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content, encoding="utf-8")
    else:
        print(content, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
