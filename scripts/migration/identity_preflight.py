#!/usr/bin/env python3
"""账号身份迁移只读预检。

脚本只执行聚合查询，不返回或写出 Email、StudentID、IP、Cookie、Token 及其
冲突明细。生产运行前由 DBA 在受控环境提供只读数据库连接；未提供连接时可用
``--dry-run`` 检查查询清单和报告结构。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from collections.abc import Callable
from typing import Any, Iterable
from urllib.parse import quote
from zoneinfo import ZoneInfo


SCHEMA_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SHANGHAI = ZoneInfo("Asia/Shanghai")


# 每个查询只返回一个聚合数字；不要在这里增加 SELECT 原始标识的语句。
METRIC_QUERIES: dict[str, tuple[str, tuple[str, ...]]] = {
    "total_users": ("SELECT COUNT(*) FROM users", ()),
    "email_empty": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(email, '') = ''",
        ("email",),
    ),
    "email_unverified": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(email, '') <> '' AND email_verified_at IS NULL",
        ("email", "email_verified_at"),
    ),
    "email_lower_duplicate_groups": (
        "SELECT COUNT(*) FROM (SELECT LOWER(email) FROM users WHERE COALESCE(email, '') <> '' GROUP BY LOWER(email) HAVING COUNT(*) > 1) AS duplicate_groups",
        ("email",),
    ),
    "qq_compatibility_email": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(qq, '') <> '' AND LOWER(COALESCE(email, '')) = LOWER(qq || '@qq.com')",
        ("qq", "email"),
    ),
    "only_student_id": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(student_id, '') <> '' AND COALESCE(email, '') = ''",
        ("student_id", "email"),
    ),
    "student_id_duplicate_groups": (
        "SELECT COUNT(*) FROM (SELECT student_id FROM users WHERE COALESCE(student_id, '') <> '' GROUP BY student_id HAVING COUNT(*) > 1) AS duplicate_groups",
        ("student_id",),
    ),
    "active_users": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(account_status, 'active') = 'active'",
        ("account_status",),
    ),
    "cancelled_users": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(account_status, '') = 'cancelled' OR cancelled_at IS NOT NULL",
        ("account_status", "cancelled_at"),
    ),
    "administrator_accounts": (
        "SELECT COUNT(*) FROM users WHERE role IN ('admin', 'super_admin')",
        ("role",),
    ),
    "registration_cleanup_pending": (
        "SELECT COUNT(*) FROM users WHERE COALESCE(account_status, '') = 'registration_cleanup_pending' OR COALESCE(edu_cleanup_pending, FALSE) = TRUE",
        ("account_status", "edu_cleanup_pending"),
    ),
}


def _script_sha256() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def _base_sha() -> str:
    try:
        value = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=Path(__file__).resolve().parents[2],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return "unavailable"
    return value if re.fullmatch(r"[0-9a-f]{7,64}", value) else "unavailable"


def _sqlite_read_only_uri(dsn: str) -> str:
    """将 sqlite:// DSN 转换为不会创建文件的 SQLite URI。

    同时兼容 Unix 的 ``sqlite:///tmp/x.db`` 和 Windows 的
    ``sqlite:///C:/path/x.db``；不接受内存数据库，避免把预检误当成生产快照。
    """

    raw = dsn.removeprefix("sqlite://")
    if raw.startswith("file:"):
        # 调用方若已提供 URI，强制只读模式；显式 rw/rwc 直接拒绝。
        mode_match = re.search(r"(?:[?&])mode=([^&]+)", raw, re.IGNORECASE)
        if mode_match and mode_match.group(1).lower() != "ro":
            raise ValueError("SQLite 预检只允许 mode=ro")
        if "::memory:" in raw.lower():
            raise ValueError("SQLite 预检必须使用已有文件，不支持内存数据库")
        separator = "&" if "?" in raw else "?"
        return raw if mode_match else raw + separator + "mode=ro"
    if raw in {":memory:", "/:memory:"} or raw == "":
        raise ValueError("SQLite 预检必须使用已有文件，不支持内存数据库")
    # URI 形式在 Windows 下会把盘符写成 /C:/...，去掉仅这一层前导斜线。
    if re.match(r"^/[A-Za-z]:[\\/]", raw):
        raw = raw[1:]
    path = Path(raw).expanduser().resolve()
    # quote 保留路径分隔符、盘符冒号和 URI 所需的斜线，空格等字符安全编码。
    encoded = quote(path.as_posix(), safe="/:\\")
    return f"file:{encoded}?mode=ro"


class ReadOnlyDB:
    """极小数据库适配器，避免报告层依赖 ORM 或打印驱动异常中的连接信息。"""

    def __init__(self, dsn: str, schema: str) -> None:
        self.kind = "postgres"
        self.conn: Any
        if dsn.startswith("sqlite://"):
            import sqlite3

            uri = _sqlite_read_only_uri(dsn)
            # SQLite 使用只读 URI；不存在的文件不会被脚本创建。
            self.conn = sqlite3.connect(uri, uri=True)
            self.kind = "sqlite"
        else:
            self.conn = self._connect_postgres(dsn)
            with self.conn.cursor() as cursor:
                cursor.execute("BEGIN READ ONLY")
                if schema != "public":
                    cursor.execute(f'SET LOCAL search_path TO "{schema}", public')

    @staticmethod
    def _connect_postgres(dsn: str) -> Any:
        try:
            import psycopg  # type: ignore

            return psycopg.connect(dsn, connect_timeout=10)
        except ImportError:
            try:
                import psycopg2  # type: ignore

                return psycopg2.connect(dsn, connect_timeout=10)
            except ImportError as exc:
                raise RuntimeError("未安装 PostgreSQL 只读驱动，请安装 psycopg 或 psycopg2") from exc

    def columns(self, table: str) -> set[str]:
        if self.kind == "sqlite":
            rows = self.conn.execute(f"PRAGMA table_info({table})").fetchall()
            return {str(row[1]) for row in rows}
        with self.conn.cursor() as cursor:
            cursor.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = current_schema() AND table_name = %s",
                (table,),
            )
            return {str(row[0]) for row in cursor.fetchall()}

    def scalar(self, query: str) -> int:
        if self.kind == "sqlite":
            row = self.conn.execute(query).fetchone()
        else:
            with self.conn.cursor() as cursor:
                cursor.execute(query)
                row = cursor.fetchone()
        if not row:
            return 0
        return int(row[0] or 0)

    def close(self) -> None:
        self.conn.close()


MetricValue = int | None


def _run_metrics(db: ReadOnlyDB) -> tuple[dict[str, MetricValue], list[str]]:
    columns = db.columns("users")
    metrics: dict[str, MetricValue] = {}
    skipped: list[str] = []
    for name, (query, required) in METRIC_QUERIES.items():
        if not set(required).issubset(columns):
            skipped.append(name)
            # 缺列是“不可用”而不是零；零会被下游误当成真实生产证据。
            metrics[name] = None
            continue
        try:
            metrics[name] = db.scalar(query)
        except Exception as exc:  # pragma: no cover - 驱动差异只记录指标名
            raise RuntimeError(f"聚合查询失败: {name}") from exc
    return metrics, skipped


def _categories(metrics: dict[str, MetricValue]) -> dict[str, dict[str, Any]]:
    # 分类优先级固定，重叠用户只在说明中标记，不输出任何用户明细。
    def metric(name: str) -> int:
        value = metrics.get(name)
        if value is None:
            raise ValueError(f"metric unavailable: {name}")
        return value

    def category(
        required: tuple[str, ...],
        count: Callable[[], int],
        *,
        auto_migrate: bool | str,
        user_action_required: bool,
        manual_review: bool | Callable[[], bool],
    ) -> dict[str, Any]:
        missing = sorted(name for name in required if metrics.get(name) is None)
        if missing:
            return {
                "count": None,
                "status": "skipped_missing_metrics",
                "missing_metrics": missing,
                # 缺少证据时禁止自动迁移，也不猜测用户操作或人工审核结论。
                "auto_migrate": False,
                "user_action_required": None,
                "manual_review": None,
            }
        return {
            "count": count(),
            "status": "available",
            "missing_metrics": [],
            "auto_migrate": auto_migrate,
            "user_action_required": user_action_required,
            "manual_review": manual_review() if callable(manual_review) else manual_review,
        }

    return {
        "A_verified_real_email": category(
            ("total_users", "email_empty", "email_unverified", "qq_compatibility_email"),
            lambda: max(
                metric("total_users")
                - metric("email_empty")
                - metric("email_unverified")
                - metric("qq_compatibility_email"),
                0,
            ),
            auto_migrate=True,
            user_action_required=False,
            manual_review=False,
        ),
        "B_qq_compatibility_email": category(
            ("qq_compatibility_email", "email_lower_duplicate_groups"),
            lambda: metric("qq_compatibility_email"),
            auto_migrate="仅在冲突为零时",
            user_action_required=False,
            manual_review=lambda: metric("email_lower_duplicate_groups") > 0,
        ),
        "C_email_unverified": category(
            ("email_unverified",),
            lambda: metric("email_unverified"),
            auto_migrate=False,
            user_action_required=True,
            manual_review=False,
        ),
        "D_no_email": category(
            ("email_empty",),
            lambda: metric("email_empty"),
            auto_migrate=False,
            user_action_required=True,
            manual_review=False,
        ),
        "E_email_conflict": category(
            ("email_lower_duplicate_groups",),
            lambda: metric("email_lower_duplicate_groups"),
            auto_migrate=False,
            user_action_required=False,
            manual_review=True,
        ),
        "F_incomplete_registration": category(
            ("registration_cleanup_pending",),
            lambda: metric("registration_cleanup_pending"),
            auto_migrate=False,
            user_action_required=False,
            manual_review=True,
        ),
    }


def _repeat_delta(
    previous: Path | None, metrics: dict[str, MetricValue]
) -> dict[str, MetricValue] | str:
    if previous is None:
        return "not_provided"
    try:
        old = json.loads(previous.read_text(encoding="utf-8"))
        old_metrics = old.get("metrics", {})
        if not isinstance(old_metrics, dict):
            return "unavailable"
        delta: dict[str, MetricValue] = {}
        for key, value in metrics.items():
            old_value = old_metrics.get(key)
            if (
                value is None
                or not isinstance(old_value, int)
                or isinstance(old_value, bool)
            ):
                delta[key] = None
            else:
                delta[key] = value - old_value
        return delta
    except (OSError, ValueError, TypeError):
        return "unavailable"


def build_report(
    metrics: dict[str, MetricValue], skipped: Iterable[str], previous: Path | None = None
) -> dict[str, Any]:
    return {
        "report_version": "identity-preflight-v1",
        "read_only": True,
        "database_snapshot_at": datetime.now(SHANGHAI).isoformat(timespec="seconds"),
        "base_sha": _base_sha(),
        "script_sha256": _script_sha256(),
        "metrics": metrics,
        "categories": _categories(metrics),
        "skipped_metrics_due_to_schema": sorted(skipped),
        "repeat_run_delta": _repeat_delta(previous, metrics),
        "processing_policy": {
            "raw_identifiers_persisted": False,
            "conflict_detail_destination": "受访问控制且自动过期的临时工作区（不进入 Git/CI）",
            "student_id_or_email_auto_created": False,
        },
    }


def _markdown(report: dict[str, Any]) -> str:
    lines = [
        "# Account Identity Preflight（脱敏聚合）",
        "",
        "> 本报告由只读脚本生成，只包含聚合计数；原始 Email、StudentID、IP、Cookie、Token 和冲突明细不得写入 Git。",
        "",
        f"- 数据库只读快照时间：`{report['database_snapshot_at']}`",
        f"- Base SHA：`{report['base_sha']}`",
        f"- 查询脚本 SHA-256：`{report['script_sha256']}`",
        f"- 只读事务：`{report['read_only']}`",
        "",
        "## 统计",
        "",
        "| 指标 | 数量 |",
        "| --- | ---: |",
    ]
    for key, value in report["metrics"].items():
        lines.append(f"| `{key}` | {'unavailable' if value is None else value} |")
    lines.extend(
        [
            "",
            "## 用户分类",
            "",
            "| 分类 | 数量 | 状态 | 缺失指标 | 自动迁移 | 需用户操作 | 人工审核 |",
            "| --- | ---: | --- | --- | --- | --- | --- |",
        ]
    )
    for key, value in report["categories"].items():
        count = "unavailable" if value["count"] is None else value["count"]
        missing = ", ".join(value["missing_metrics"]) or "无"
        lines.append(
            f"| `{key}` | {count} | {value['status']} | {missing} | {value['auto_migrate']} | {value['user_action_required']} | {value['manual_review']} |"
        )
    lines.extend(
        [
            "",
            "## 复跑与边界",
            "",
            f"- Schema 缺失而跳过的聚合指标：`{', '.join(report['skipped_metrics_due_to_schema']) or '无'}`",
            f"- 与上次报告的聚合差异：`{json.dumps(report['repeat_run_delta'], ensure_ascii=False, sort_keys=True)}`",
            "- 处理策略：只回填已验证且无冲突的邮箱；冲突隔离，不覆盖、不创建假邮箱；Session 不保存学校凭据或校园事实。",
            "",
            "## 依赖清单",
            "",
            "静态依赖盘点见 `scripts/migration/identity_dependency_inventory.py` 生成的聚合结果；读取、写入、响应输出、索引/约束和测试 Fixture 必须在 DROP 前复核。",
        ]
    )
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="账号身份迁移只读预检")
    parser.add_argument("--dsn", help="只读 PostgreSQL DSN，或本地 sqlite:///path（不写库）")
    parser.add_argument("--schema", default="public", help="PostgreSQL schema 名称")
    parser.add_argument("--output", type=Path, help="输出 JSON/Markdown 报告路径")
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--previous", type=Path, help="上一次 JSON 聚合报告，用于计算差异")
    parser.add_argument("--dry-run", action="store_true", help="只输出查询清单，不连接数据库")
    args = parser.parse_args(argv)
    if not SCHEMA_RE.fullmatch(args.schema):
        parser.error("schema 只能包含 ASCII 字母、数字和下划线")
    if not args.dry_run and not args.dsn:
        parser.error("生产预检必须提供 --dsn；无需连接时请使用 --dry-run")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.dry_run:
        print(json.dumps({"read_only": True, "query_names": sorted(METRIC_QUERIES), "script_sha256": _script_sha256()}, ensure_ascii=False, indent=2))
        return 0
    db: ReadOnlyDB | None = None
    try:
        db = ReadOnlyDB(args.dsn, args.schema)
        metrics, skipped = _run_metrics(db)
        report = build_report(metrics, skipped, args.previous)
        if args.format == "markdown":
            content = _markdown(report)
        else:
            content = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(content, encoding="utf-8")
        else:
            print(content, end="")
        return 0
    except Exception:
        # 不把驱动错误、DSN 或查询参数回显到终端/CI Artifact。
        print("身份预检失败：只读连接或聚合查询不可用", file=sys.stderr)
        return 2
    finally:
        if db is not None:
            db.close()


if __name__ == "__main__":
    raise SystemExit(main())
