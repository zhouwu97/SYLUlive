"""从 v0.7 政策 Markdown 文档生成管理端可导入 JSONL。"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DOCUMENTS = ROOT / "documents"
OUTPUT = ROOT / "SYLUlive_AI学生资助政策增量导入包_v0.7.jsonl"
REQUIRED_FIELDS = {
    "title",
    "source_type",
    "source_uri",
    "source_file_name",
    "document_type",
    "department",
    "effective_from",
    "effective_to",
}


def parse_document(path: Path) -> dict[str, str]:
    """读取受限 YAML frontmatter，避免引入额外运行时依赖。"""

    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("---\n"):
        raise ValueError(f"{path.name} 缺少 frontmatter")
    _, frontmatter, content = raw.split("---\n", 2)
    metadata: dict[str, str] = {}
    for line in frontmatter.strip().splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            raise ValueError(f"{path.name} frontmatter 格式错误：{line}")
        metadata[key.strip()] = value.strip().strip('"')
    missing = REQUIRED_FIELDS.difference(metadata)
    if missing:
        raise ValueError(f"{path.name} 缺少字段：{', '.join(sorted(missing))}")
    if not content.strip():
        raise ValueError(f"{path.name} 正文为空")
    metadata["content"] = content.strip() + "\n"
    return metadata


def build() -> list[dict[str, str]]:
    """按文件名稳定排序，保证重复生成的导入包字节一致。"""

    return [parse_document(path) for path in sorted(DOCUMENTS.glob("*.md"))]


def main() -> None:
    """输出每行一个知识文档的 JSONL。"""

    records = build()
    OUTPUT.write_text(
        "".join(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n" for record in records),
        encoding="utf-8",
    )
    print(f"已生成 {OUTPUT.name}：{len(records)} 条文档")


if __name__ == "__main__":
    main()
