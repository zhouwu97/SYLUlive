"""生成 v0.8 管理端导入包、独立 MCP Bundle 和完整性清单。"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DOCUMENTS = ROOT / "documents"
CONTRACT = ROOT / "policy_query_contract_v0.8.json"
IMPORT_OUTPUT = ROOT / "SYLUlive_AI学生资助政策拆分导入包_v0.8.jsonl"
RELEASE_OUTPUT = ROOT / "SYLUlive_AI学生资助政策完整导入包_v0.8.jsonl"
BUNDLE_OUTPUT = ROOT / "sylulive-policy-bundle-v0.8.jsonl"
MANIFEST_OUTPUT = ROOT / "policy-bundle-manifest.json"
UNDERGRADUATE = ROOT.parent / "v0.7" / "documents" / "sylu-undergraduate-scholarships-policy-2022.md"


def parse_document(path: Path) -> dict[str, str]:
    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("---\n"):
        raise ValueError(f"{path.name} 缺少 frontmatter")
    _, frontmatter, content = raw.split("---\n", 2)
    metadata: dict[str, str] = {}
    for line in frontmatter.strip().splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            raise ValueError(f"{path.name} frontmatter 格式错误")
        metadata[key.strip()] = value.strip().strip('"')
    required = {"title", "source_type", "source_uri", "source_file_name", "document_type", "department", "effective_from", "effective_to"}
    missing = required.difference(metadata)
    if missing or not content.strip():
        raise ValueError(f"{path.name} 缺少字段或正文：{sorted(missing)}")
    if len(metadata["source_type"]) > 32:
        raise ValueError(f"{path.name} 的 source_type 超过数据库 32 字符限制")
    metadata["content"] = content.strip() + "\n"
    return metadata


def sha256(data: bytes) -> str:
    """按 LF 规范化换行后计算发布摘要，保证 Windows 与 Linux 一致。"""

    normalized = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return hashlib.sha256(normalized).hexdigest()


def main() -> None:
    split_records = [parse_document(path) for path in sorted(DOCUMENTS.glob("*.md"))]
    bundle_records = [parse_document(UNDERGRADUATE), *split_records]
    import_bytes = b"".join((json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n").encode() for item in split_records)
    release_bytes = b"".join((json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n").encode() for item in bundle_records)
    bundle_bytes = b"".join((json.dumps({**item, "category": "policy", "source_id": f"sylulive-v0.8-{item['document_type']}"}, ensure_ascii=False, separators=(",", ":")) + "\n").encode() for item in bundle_records)
    IMPORT_OUTPUT.write_bytes(import_bytes)
    RELEASE_OUTPUT.write_bytes(release_bytes)
    BUNDLE_OUTPUT.write_bytes(bundle_bytes)
    try:
        source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        source_commit = "unknown"
    manifest = {
        "version": "v0.8",
        "source_commit": source_commit,
        "document_count": len(bundle_records),
        "sha256_canonicalization": "newline-lf-v1",
        "documents_sha256": sha256(bundle_bytes),
        "intent_contract_sha256": sha256(CONTRACT.read_bytes()),
        "unresolved_source_conflicts": ["school_work_study_policy:failed_course_count_exactly_two"],
    }
    MANIFEST_OUTPUT.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"生成增量导入文档 {len(split_records)} 条，"
        f"完整发布和 Bundle 文档各 {len(bundle_records)} 条"
    )


if __name__ == "__main__":
    main()
