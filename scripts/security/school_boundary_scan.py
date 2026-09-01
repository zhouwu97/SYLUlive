#!/usr/bin/env python3
"""SYLUlive 学校权限边界静态扫描器。

该脚本是 PR0/PR1 的 CI 门禁，不执行网络请求，也不会读取运行时密钥。它做三类
检查：

* 生产源码（``server`` 与 ``python-edu-service``）不得关闭 TLS 校验；
* Dockerfile 与忽略文件必须能证明测试/探针不会进入运行时镜像；
* Flutter 的临时证书兼容回调必须限定在一个文件，并标注 Owner 与 PR6 删除边界。

探针目录中的坏证书模拟代码不会被永久关键词白名单“放行”。它们只有在实际的
Docker 发布边界把对应文件排除后，才会被报告为 ``excluded``；若发布边界失效，
扫描直接失败。
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
import tarfile
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Iterable, Iterator, Mapping, Sequence


SCHEMA_VERSION = "school-boundary-scan.v1"

# 这些模式必须保持为源码级规则：不能用永久 allowlist 掩盖生产命中。
DANGEROUS_PATTERNS: Mapping[str, re.Pattern[str]] = {
    "verify_false": re.compile(r"\bverify\s*=\s*False\b"),
    "cert_none": re.compile(r"\bCERT_NONE\b"),
}
FLUTTER_CALLBACK_PATTERN = re.compile(r"\bbadCertificateCallback\b")

_PYTHON_EXCLUDED_DIRS = {
    ".git",
    ".pytest_cache",
    "__pycache__",
    "tests",
    "tools",
    "output",
    "private-probe-output",
}
_SERVER_EXCLUDED_DIRS = {
    ".git",
    ".pytest_cache",
    "testdata",
    "uploads",
    "dist",
}
_TEXT_SUFFIXES = {
    ".c",
    ".cc",
    ".conf",
    ".cpp",
    ".cs",
    ".dart",
    ".go",
    ".ini",
    ".js",
    ".json",
    ".md",
    ".py",
    ".sh",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".yaml",
    ".yml",
}


@dataclass(frozen=True)
class Finding:
    """不包含源码内容的命中记录，避免 CI 输出意外泄露凭据。"""

    check_id: str
    path: str
    line: int
    column: int
    rule: str

    def as_dict(self) -> dict[str, object]:
        return {
            "check_id": self.check_id,
            "path": self.path,
            "line": self.line,
            "column": self.column,
            "rule": self.rule,
        }


def _posix_relative(path: Path, root: Path) -> str:
    """生成稳定的 POSIX 相对路径，便于 Windows 与 Linux CI 对比。"""

    return path.relative_to(root).as_posix()


def _is_probably_text(path: Path) -> bool:
    if path.suffix.lower() in _TEXT_SUFFIXES or path.name in {
        "Dockerfile",
        ".dockerignore",
    }:
        return True
    try:
        sample = path.read_bytes()[:4096]
    except OSError:
        return False
    return b"\x00" not in sample


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _iter_files(root: Path, excluded_dirs: set[str]) -> Iterator[Path]:
    """遍历源码，同时明确排除本地生成物和已声明的非生产目录。"""

    if not root.exists():
        return
    for path in sorted(root.rglob("*")):
        if not path.is_file() or not _is_probably_text(path):
            continue
        try:
            relative_parts = path.relative_to(root).parts
        except ValueError:
            continue
        if any(part in excluded_dirs for part in relative_parts):
            continue
        # Python 测试脚本可能位于包根，而不是 tests/ 目录；它们属于探针/测试边界。
        if root.name == "python-edu-service" and path.suffix == ".py":
            if path.name.startswith("test"):
                continue
        # Go 单元测试不属于运行时二进制的源码边界。
        if root.name == "server" and path.name.endswith("_test.go"):
            continue
        yield path


def _find_patterns(
    paths: Iterable[Path],
    repo_root: Path,
    patterns: Mapping[str, re.Pattern[str]] = DANGEROUS_PATTERNS,
    check_id: str = "production-tls",
) -> list[Finding]:
    findings: list[Finding] = []
    for path in paths:
        text = _read_text(path)
        for line_number, line in enumerate(text.splitlines(), start=1):
            for rule, pattern in patterns.items():
                match = pattern.search(line)
                if match:
                    findings.append(
                        Finding(
                            check_id=check_id,
                            path=_posix_relative(path, repo_root),
                            line=line_number,
                            column=match.start() + 1,
                            rule=rule,
                        )
                    )
    return findings


def _check_dict(
    check_id: str,
    status: str,
    *,
    details: Mapping[str, object] | None = None,
    findings: Sequence[Finding] = (),
) -> dict[str, object]:
    result: dict[str, object] = {
        "id": check_id,
        "status": status,
        "findings": [finding.as_dict() for finding in findings],
    }
    if details:
        result["details"] = dict(details)
    return result


def _production_tls_check(repo_root: Path) -> dict[str, object]:
    roots = {
        "server": repo_root / "server",
        "python-edu-service": repo_root / "python-edu-service",
    }
    findings: list[Finding] = []
    files_scanned = 0
    for name, root in roots.items():
        paths = list(_iter_files(root, _SERVER_EXCLUDED_DIRS if name == "server" else _PYTHON_EXCLUDED_DIRS))
        files_scanned += len(paths)
        findings.extend(_find_patterns(paths, repo_root, check_id=f"{name}-production-tls"))
    return _check_dict(
        "production-tls",
        "fail" if findings else "pass",
        details={"files_scanned": files_scanned, "rules": sorted(DANGEROUS_PATTERNS)},
        findings=findings,
    )


def _dockerignore_patterns(path: Path) -> list[str]:
    if not path.exists():
        return []
    patterns: list[str] = []
    for raw_line in _read_text(path).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(line)
    return patterns


def _docker_pattern_matches(relative_path: str, pattern: str) -> bool:
    """实现发布证明所需的 Docker ignore 子集（含目录、通配符和反选）。"""

    candidate = relative_path.replace("\\", "/").lstrip("/")
    normalized = pattern.strip().replace("\\", "/")
    if normalized.startswith("!"):
        normalized = normalized[1:]
    normalized = normalized.lstrip("/")
    if normalized.endswith("/"):
        normalized = normalized.rstrip("/")
        return candidate == normalized or candidate.startswith(normalized + "/")
    if candidate == normalized or candidate.startswith(normalized + "/"):
        return True
    if fnmatch.fnmatch(candidate, normalized):
        return True
    if fnmatch.fnmatch(candidate, f"**/{normalized}"):
        return True
    # Docker 的无斜杠模式按 basename 匹配，例如 test*.py。
    if "/" not in normalized and fnmatch.fnmatch(PurePosixPath(candidate).name, normalized):
        return True
    return False


def is_docker_ignored(relative_path: str, patterns: Sequence[str]) -> bool:
    """按 Dockerfile 忽略规则判断路径是否不会被 COPY . . 带入上下文。"""

    ignored = False
    for raw_pattern in patterns:
        pattern = raw_pattern.strip()
        if not pattern or pattern.startswith("#"):
            continue
        negated = pattern.startswith("!")
        if _docker_pattern_matches(relative_path, pattern):
            ignored = not negated
    return ignored


def _python_artifact_check(repo_root: Path) -> dict[str, object]:
    service_root = repo_root / "python-edu-service"
    dockerfile = service_root / "Dockerfile"
    ignore_file = service_root / ".dockerignore"
    patterns = _dockerignore_patterns(ignore_file)
    probe_paths = (
        "tests/test_session.py",
        "tools/edu_probe/crawler_probe.py",
        "tools/jwc_public_probe/inspect_homepage.py",
        "test_erke.py",
    )
    excluded = [path for path in probe_paths if is_docker_ignored(path, patterns)]
    missing = [path for path in probe_paths if path not in excluded]
    dockerfile_text = _read_text(dockerfile) if dockerfile.exists() else ""
    broad_copy = bool(re.search(r"(?m)^\s*COPY\s+\.\s+\.\s*$", dockerfile_text))
    explicit_probe_copy = bool(
        re.search(r"(?im)^\s*COPY\s+(?:[^#\n]*\b(?:tests|tools|test[^\s/]*)\b)", dockerfile_text)
    )
    failures: list[str] = []
    if not dockerfile.exists():
        failures.append("python Dockerfile 不存在")
    if broad_copy and not ignore_file.exists():
        failures.append("Dockerfile 使用 COPY . . 但缺少 .dockerignore")
    if missing:
        failures.append("探针/测试路径未被 .dockerignore 排除: " + ", ".join(missing))
    if explicit_probe_copy:
        failures.append("Dockerfile 显式复制了测试或探针路径")
    status = "fail" if failures else "pass"
    return _check_dict(
        "python-release-boundary",
        status,
        details={
            "dockerfile": _posix_relative(dockerfile, repo_root),
            "dockerignore": _posix_relative(ignore_file, repo_root) if ignore_file.exists() else None,
            "copy_dot_context": broad_copy,
            "probe_paths": list(probe_paths),
            "excluded_probe_paths": excluded,
            "failures": failures,
        },
    )


def _server_artifact_check(repo_root: Path) -> dict[str, object]:
    dockerfile = repo_root / "server" / "Dockerfile"
    text = _read_text(dockerfile) if dockerfile.exists() else ""
    # 运行时 stage 只能复制编译后的单一二进制；builder 中的 testdata 不会发布。
    final_binary_copy = bool(
        re.search(r"(?im)^\s*COPY\s+--from=builder\s+/app/server\s+\.\s*$", text)
    )
    failures: list[str] = []
    if not dockerfile.exists():
        failures.append("server Dockerfile 不存在")
    if not final_binary_copy:
        failures.append("server runtime stage 未证明只复制 /app/server 二进制")
    return _check_dict(
        "server-release-boundary",
        "fail" if failures else "pass",
        details={
            "dockerfile": _posix_relative(dockerfile, repo_root),
            "runtime_binary_only": final_binary_copy,
            "failures": failures,
        },
    )


def _excluded_source_check(repo_root: Path) -> dict[str, object]:
    """扫描测试/探针命中，并要求发布边界另外证明其不会进镜像。"""

    findings: list[Finding] = []
    roots = (
        (repo_root / "python-edu-service" / "tests", "python-excluded-tls"),
        (repo_root / "python-edu-service" / "tools", "python-probe-tls"),
        (repo_root / "python-edu-service", "python-root-test-tls"),
        (repo_root / "server" / "testdata", "server-testdata-tls"),
    )
    for root, check_id in roots:
        if not root.exists():
            continue
        # 根目录扫描只取测试脚本，避免重复扫描生产源码。
        if check_id == "python-root-test-tls":
            paths = [p for p in root.glob("test*.py") if p.is_file()]
        else:
            paths = list(_iter_files(root, set()))
        findings.extend(_find_patterns(paths, repo_root, check_id=check_id))
    return _check_dict(
        "excluded-source-observation",
        "pass",
        details={
            "purpose": "仅记录非生产源码命中；是否可发布由 release-boundary 检查决定",
            "finding_count": len(findings),
        },
        findings=findings,
    )


def _flutter_tls_check(repo_root: Path) -> dict[str, object]:
    client_root = repo_root / "client" / "lib"
    findings: list[Finding] = []
    callback_files: list[str] = []
    metadata_missing: list[str] = []
    if client_root.exists():
        for path in sorted(client_root.rglob("*.dart")):
            text = _read_text(path)
            if not FLUTTER_CALLBACK_PATTERN.search(text):
                continue
            relative = _posix_relative(path, repo_root)
            callback_files.append(relative)
            for line_number, line in enumerate(text.splitlines(), start=1):
                match = FLUTTER_CALLBACK_PATTERN.search(line)
                if match:
                    findings.append(
                        Finding(
                            check_id="flutter-tls-allowlist",
                            path=relative,
                            line=line_number,
                            column=match.start() + 1,
                            rule="bad_certificate_callback",
                        )
                    )
                    break
            # 临时兼容策略必须写明责任人与 PR6 删除承诺，不能只靠日期续期。
            if not re.search(r"(?i)owner\s*[:：]", text) or "PR6" not in text:
                metadata_missing.append(relative)
    unexpected = [path for path in callback_files if path != "client/lib/services/webvpn_tls_config_io.dart"]
    failures = []
    if unexpected:
        failures.append("badCertificateCallback 出现在非批准文件: " + ", ".join(unexpected))
    if metadata_missing:
        failures.append("临时回调缺少 Owner 或 PR6 删除边界: " + ", ".join(metadata_missing))
    return _check_dict(
        "flutter-tls-allowlist",
        "fail" if failures else "pass",
        details={
            "callback_files": callback_files,
            "metadata_missing": metadata_missing,
            "failures": failures,
        },
        findings=findings,
    )


def _archive_names(path: Path) -> list[str]:
    suffixes = [suffix.lower() for suffix in path.suffixes]
    if path.is_dir():
        return [p.relative_to(path).as_posix() for p in path.rglob("*") if p.is_file()]
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as archive:
            return [name.replace("\\", "/") for name in archive.namelist() if not name.endswith("/")]
    if ".tar" in suffixes or path.suffix.lower() in {".tgz", ".tbz", ".tbz2"}:
        with tarfile.open(path, mode="r:*") as archive:
            return [member.name.replace("\\", "/") for member in archive.getmembers() if member.isfile()]
    raise ValueError(f"不支持的发布物格式: {path}")


def _release_artifact_check(repo_root: Path, artifact: Path | None) -> dict[str, object] | None:
    if artifact is None:
        return None
    try:
        names = _archive_names(artifact)
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as exc:
        return _check_dict(
            "release-artifact",
            "fail",
            details={"artifact": str(artifact), "error": str(exc)},
        )
    forbidden: list[str] = []
    for name in names:
        normalized = name.lstrip("./")
        parts = set(PurePosixPath(normalized).parts)
        if parts.intersection({"tests", "tools", "testdata", "__pycache__"}) or PurePosixPath(normalized).name.startswith("test"):
            forbidden.append(name)
    # 目录发布物可直接读取；压缩包只检查名称，避免解压写入工作区。
    findings: list[Finding] = []
    if artifact.is_dir():
        files = [p for p in artifact.rglob("*") if p.is_file() and _is_probably_text(p)]
        findings.extend(_find_patterns(files, artifact, check_id="release-artifact-tls"))
    failures = []
    if forbidden:
        failures.append("发布物包含测试/探针文件: " + ", ".join(forbidden[:20]))
    if findings:
        failures.append("发布物包含危险 TLS 关键词")
    return _check_dict(
        "release-artifact",
        "fail" if failures else "pass",
        details={
            "artifact": str(artifact),
            "file_count": len(names),
            "forbidden_count": len(forbidden),
            "failures": failures,
        },
        findings=findings,
    )


def scan_repository(repo_root: str | Path, artifact: str | Path | None = None) -> dict[str, object]:
    """扫描仓库并返回可供 CI/审计保存的结构化结果。"""

    root = Path(repo_root).resolve()
    artifact_path = Path(artifact).resolve() if artifact is not None else None
    checks = [
        _production_tls_check(root),
        _python_artifact_check(root),
        _server_artifact_check(root),
        _excluded_source_check(root),
        _flutter_tls_check(root),
    ]
    release_check = _release_artifact_check(root, artifact_path)
    if release_check is not None:
        checks.append(release_check)
    failures = [check for check in checks if check.get("status") == "fail"]
    finding_count = sum(len(check.get("findings", [])) for check in checks)
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "fail" if failures else "pass",
        "repository": str(root),
        "scanned_at": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "checks": len(checks),
            "failed_checks": len(failures),
            "finding_count": finding_count,
        },
        "checks": checks,
    }


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="扫描 SYLUlive 学校权限边界并输出 JSON")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2], help="仓库根目录")
    parser.add_argument("--artifact", type=Path, help="可选的已构建发布物目录/zip/tar")
    parser.add_argument("--format", choices=("json", "text"), default="json", help="输出格式，默认 JSON")
    parser.add_argument("--pretty", action="store_true", help="缩进输出 JSON")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    report = scan_repository(args.root, args.artifact)
    if args.format == "text":
        print(
            f"school_boundary_scan: {report['status']} "
            f"({report['summary']['failed_checks']} failed checks, "
            f"{report['summary']['finding_count']} findings)"
        )
    else:
        print(json.dumps(report, ensure_ascii=False, indent=2 if args.pretty else None, sort_keys=True))
    return 1 if report["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
