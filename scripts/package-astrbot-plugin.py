"""Package only the installable plugin, without local credentials or test caches."""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo
import hashlib
import json
import re
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / "astrbot_plugin_sylulive"
output = root / "dist" / "astrbot_plugin_sylulive.zip"
files = [
    "main.py",
    "client.py",
    "credential_store.py",
    "accounts.py",
    "administration.py",
    "permissions.py",
    "binding_delivery.py",
    "binding_notifications.py",
    "group_confirmations.py",
    "personal.py",
    "private_review.py",
    "public_canteen.py",
    "public_agent.py",
    "public_activity.py",
    "managed_bot_access.py",
    "bot_runtime.py",
    "creator_memory.py",
    "community_publisher.py",
    "community_view.py",
    "approved_media.py",
    "chat_media.py",
    "chat_context.py",
    "permission_console.py",
    "pages/permissions/index.html",
    "pages/permissions/app.css",
    "pages/permissions/app.js",
    "astrbot_persona.py",
    "permission_policy.py",
    "THIRD_PARTY_NOTICES.md",
    "metadata.yaml",
    "_conf_schema.json",
    "requirements.txt",
    "README.md",
]
for name in files:
    if not (source / name).is_file():
        raise SystemExit(f"Missing plugin file: {name}")
output.parent.mkdir(parents=True, exist_ok=True)
contents = {name: (source / name).read_bytes() for name in files}
try:
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True, timeout=5).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain", "--", "astrbot_plugin_sylulive", "scripts/package-astrbot-plugin.py"], cwd=root, capture_output=True, text=True, check=True, timeout=5).stdout.strip())
except (OSError, subprocess.SubprocessError):
    revision, dirty = None, True
version = re.search(r'^version:\s*v?([^\s]+)', contents['metadata.yaml'].decode(), re.MULTILINE).group(1)
manifest = {"version": version, "source_commit": revision, "source_dirty": dirty,
            "files": {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}}
contents["build.json"] = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
    for name, data in contents.items():
        # 不继承工作树的时间和权限；相同源码在不同检出目录仍生成相同归档。
        entry = ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = 0o100644 << 16
        entry.compress_type = ZIP_DEFLATED
        archive.writestr(entry, data, compresslevel=9)
print(output)
print("SHA256:", hashlib.sha256(output.read_bytes()).hexdigest())
