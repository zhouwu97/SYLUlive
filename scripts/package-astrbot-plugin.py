"""Package only the installable plugin, without local credentials or test caches."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo
import hashlib

root = Path(__file__).resolve().parents[1]
source = root / "astrbot_plugin_sylulive"
output = root / "dist" / "astrbot_plugin_sylulive.zip"
files = [
    "main.py",
    "client.py",
    "credential_store.py",
    "private_review.py",
    "metadata.yaml",
    "_conf_schema.json",
    "requirements.txt",
    "README.md",
]
for name in files:
    if not (source / name).is_file():
        raise SystemExit(f"Missing plugin file: {name}")
output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
    for name in files:
        # 不继承工作树的时间和权限；相同源码在不同检出目录仍生成相同归档。
        entry = ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = 0o100644 << 16
        entry.compress_type = ZIP_DEFLATED
        archive.writestr(entry, (source / name).read_bytes(), compresslevel=9)
print(output)
print("SHA256:", hashlib.sha256(output.read_bytes()).hexdigest())
