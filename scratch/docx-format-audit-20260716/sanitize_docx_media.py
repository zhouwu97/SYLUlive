"""无损重编码 DOCX 内的 PNG，清除导致 LibreOffice 读取失败的异常块。"""

from __future__ import annotations

import io
import sys
import zipfile
from pathlib import Path

from PIL import Image


def normalize_png(data: bytes) -> bytes:
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        # 保留透明通道；非透明图片统一为 RGB，像素和尺寸均不改变。
        if image.mode in {"RGBA", "LA"} or "transparency" in image.info:
            normalized = image.convert("RGBA")
        else:
            normalized = image.convert("RGB")
        output = io.BytesIO()
        normalized.save(output, format="PNG", optimize=False, compress_level=6)
        return output.getvalue()


def main():
    if len(sys.argv) != 3:
        raise SystemExit("用法: sanitize_docx_media.py 输入.docx 输出.docx")
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    destination.parent.mkdir(parents=True, exist_ok=True)

    rewritten = []
    with zipfile.ZipFile(source, "r") as zin, zipfile.ZipFile(
        destination, "w", compression=zipfile.ZIP_DEFLATED
    ) as zout:
        for info in zin.infolist():
            if info.is_dir():
                continue
            data = zin.read(info.filename)
            if info.filename.startswith("word/media/") and info.filename.lower().endswith(
                ".png"
            ):
                old_size = len(data)
                data = normalize_png(data)
                rewritten.append((info.filename, old_size, len(data)))
            zout.writestr(info, data)

    with zipfile.ZipFile(destination, "r") as check:
        failure = check.testzip()
        if failure is not None:
            raise RuntimeError(f"DOCX 包校验失败: {failure}")
    for name, old_size, new_size in rewritten:
        print(f"{name}: {old_size} -> {new_size}")


if __name__ == "__main__":
    main()
