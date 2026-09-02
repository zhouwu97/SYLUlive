"""学校权限边界扫描器的回归测试。"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCANNER_PATH = REPO_ROOT / "scripts" / "security" / "school_boundary_scan.py"
SPEC = importlib.util.spec_from_file_location("school_boundary_scan", SCANNER_PATH)
assert SPEC and SPEC.loader
scanner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = scanner
SPEC.loader.exec_module(scanner)


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _minimal_repo(root: Path) -> None:
    _write(root / "python-edu-service" / "Dockerfile", "COPY . .\n")
    _write(
        root / "python-edu-service" / ".dockerignore",
        "tests/\ntools/\ntest*.py\n",
    )
    _write(
        root / "server" / "Dockerfile",
        "FROM golang AS builder\n"
        "COPY . .\n"
        "FROM debian\n"
        "COPY --from=builder /app/server .\n",
    )


def test_clean_fixture_passes_all_repository_checks(tmp_path: Path) -> None:
    _minimal_repo(tmp_path)

    report = scanner.scan_repository(tmp_path)

    assert report["status"] == "pass"
    assert report["schema_version"] == "school-boundary-scan.v1"
    assert report["summary"]["failed_checks"] == 0


def test_production_tls_keyword_is_a_blocking_finding(tmp_path: Path) -> None:
    _minimal_repo(tmp_path)
    _write(tmp_path / "server" / "internal" / "main.go", "client.verify=False\n")

    report = scanner.scan_repository(tmp_path)

    assert report["status"] == "fail"
    tls_check = next(check for check in report["checks"] if check["id"] == "production-tls")
    assert tls_check["status"] == "fail"
    assert tls_check["findings"][0]["path"] == "server/internal/main.go"


def test_probe_requires_an_actual_docker_exclusion(tmp_path: Path) -> None:
    _minimal_repo(tmp_path)
    _write(
        tmp_path / "python-edu-service" / "tools" / "probe.py",
        "httpx.AsyncClient(verify=False)\n",
    )
    (tmp_path / "python-edu-service" / ".dockerignore").unlink()

    report = scanner.scan_repository(tmp_path)

    boundary = next(check for check in report["checks"] if check["id"] == "python-release-boundary")
    assert boundary["status"] == "fail"
    observation = next(check for check in report["checks"] if check["id"] == "excluded-source-observation")
    assert observation["details"]["finding_count"] == 1


def test_release_directory_rejects_probe_and_insecure_tls(tmp_path: Path) -> None:
    artifact = tmp_path / "artifact"
    _write(artifact / "tools" / "probe.py", "client.verify = False\n")

    result = scanner._release_artifact_check(tmp_path, artifact)

    assert result is not None
    assert result["status"] == "fail"
    assert result["details"]["forbidden_count"] == 1
    assert result["findings"][0]["rule"] == "verify_false"


def test_erke_crawler_uses_standard_tls_validation() -> None:
    source = (REPO_ROOT / "python-edu-service" / "erke_crawler.py").read_text(encoding="utf-8")

    assert "self.session.verify = True" in source
    assert "self.session.verify = False" not in source
