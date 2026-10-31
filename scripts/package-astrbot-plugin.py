"""Package only the installable plugin, without local credentials or test caches."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile
import hashlib

root = Path(__file__).resolve().parents[1]
source = root / "astrbot_plugin_sylulive"
output = root / "dist" / "astrbot_plugin_sylulive.zip"
files = [
    "main.py",
    "client.py",
    "credential_store.py",
    "metadata.yaml",
    "_conf_schema.json",
    "requirements.txt",
    "README.md",
]
for name in files:
    if not (source / name).is_file():
        raise SystemExit(f"Missing plugin file: {name}")
output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(output, "w", ZIP_DEFLATED) as archive:
    for name in files:
        archive.write(source / name, name)
print(output)
print("SHA256:", hashlib.sha256(output.read_bytes()).hexdigest())
