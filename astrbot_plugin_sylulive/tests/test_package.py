"""校验可安装 ZIP 的允许表和跨检出时间的可复现性。"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
from zipfile import ZipFile


def test_package_is_reproducible_and_excludes_local_secrets(tmp_path):
    root = Path(__file__).resolve().parents[2]
    script = tmp_path / "scripts" / "package-astrbot-plugin.py"
    script.parent.mkdir()
    shutil.copyfile(root / "scripts" / script.name, script)
    source = tmp_path / "astrbot_plugin_sylulive"
    source.mkdir()
    allowed = {
        "main.py", "client.py", "credential_store.py", "metadata.yaml",
        "_conf_schema.json", "requirements.txt", "README.md", "private_review.py", "public_canteen.py",
    }
    for name in allowed:
        shutil.copyfile(root / source.name / name, source / name)
    for name in (".env", "token.json", "local-access.json", "cache.pyc"):
        (source / name).write_text("synthetic-local-secret", encoding="utf-8")
    (source / "SnowLuma").mkdir()
    (source / "SnowLuma" / "protocol.bin").write_bytes(b"not-distributable")

    def package():
        subprocess.run([sys.executable, str(script)], check=True, capture_output=True, timeout=15)
        return (tmp_path / "dist" / "astrbot_plugin_sylulive.zip").read_bytes()

    first = package()
    for name in allowed:
        os.utime(source / name, (1800000000, 1800000000))
    assert package() == first
    with ZipFile(tmp_path / "dist" / "astrbot_plugin_sylulive.zip") as archive:
        assert set(archive.namelist()) == allowed
        assert archive.testzip() is None
        for name in allowed:
            assert archive.read(name) == (source / name).read_bytes()
            assert archive.getinfo(name).date_time == (2020, 1, 1, 0, 0, 0)
