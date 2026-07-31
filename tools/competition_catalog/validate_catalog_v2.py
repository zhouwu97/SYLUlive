"""离线复核 Catalog 2.2 JSON 的结构、权限组合与摘要。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from _catalog_v2 import validate_document


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path)
    args = parser.parse_args()
    document = json.loads(args.catalog.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError("目录根节点必须是对象")
    errors = validate_document(document)
    result = {
        "status": "passed" if not errors else "failed",
        "item_count": len(document.get("items", [])),
        "issues": errors,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
