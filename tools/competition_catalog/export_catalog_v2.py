"""从工作簿或 CSV 离线导出 Catalog 2.2 JSON。"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from _catalog_v2 import build_document, validate_document


def read_csv(path: Path) -> list[dict[str, Any]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def read_workbook(path: Path, sheet_name: str | None) -> list[dict[str, Any]]:
    try:
        from openpyxl import load_workbook
    except ImportError as exc:
        raise RuntimeError("读取 .xlsx 需要安装 openpyxl") from exc
    workbook = load_workbook(path, read_only=True, data_only=True)
    worksheet = workbook[sheet_name] if sheet_name else workbook.active
    rows = worksheet.iter_rows(values_only=True)
    try:
        headers = [str(value).strip() if value is not None else "" for value in next(rows)]
    except StopIteration:
        return []
    if not all(headers) or len(headers) != len(set(headers)):
        raise ValueError("表头不能为空且不能重复")
    return [
        dict(zip(headers, values, strict=True))
        for values in rows
        if any(value is not None and str(value).strip() for value in values)
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="输入 .xlsx 或 .csv")
    parser.add_argument("output", type=Path, help="输出 JSON")
    parser.add_argument("--dataset-version", required=True)
    parser.add_argument("--publish-status", choices=("draft", "published"), default="draft")
    parser.add_argument("--production-load-allowed", action="store_true")
    parser.add_argument("--sheet", help="工作表名称；默认使用活动工作表")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.input.suffix.lower() == ".csv":
        rows = read_csv(args.input)
    elif args.input.suffix.lower() == ".xlsx":
        rows = read_workbook(args.input, args.sheet)
    else:
        raise ValueError("输入文件必须是 .xlsx 或 .csv")
    document = build_document(
        rows,
        dataset_version=args.dataset_version,
        publish_status=args.publish_status,
        production_load_allowed=args.production_load_allowed,
        source_filename=args.input.name,
    )
    errors = validate_document(document)
    if errors:
        raise ValueError("\n".join(errors))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        json.dumps(
            {
                "status": "ok",
                "output": str(args.output),
                "item_count": document["item_count"],
                "package_hash": document["package_hash"],
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
