"""用临时 Git 仓库和工具替身验证发布阻断，不运行 Android 构建。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "发布脚本回归使用 Windows 命令替身")
class ReleaseBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sylu-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.client = self.root / "client"
        (self.client / "scripts").mkdir(parents=True)
        (self.client / "android/app").mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("build_release.ps1"), self.client / "scripts/build_release.ps1")
        (self.client / "pubspec.yaml").write_text("version: 1.7.3+1706\n")
        (self.client / "android/key.properties").write_text(
            "storeFile=fixture.jks\nstorePassword=fixture\nkeyAlias=fixture\nkeyPassword=fixture\n")
        (self.client / "android/app/fixture.jks").write_text("tool stub, not a signing key")
        (self.root / ".gitignore").write_text("/client/build/\n/client/release-artifacts/\n/client/android/key.properties\n/tools/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Release test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.tools / "flutter.cmd").write_text(
            f'@echo off\n"{sys.executable}" "%~dp0flutter_stub.py"\nexit /b %errorlevel%\n')
        (self.tools / "flutter_stub.py").write_text(
            "import os, pathlib, subprocess, sys\n"
            "root=pathlib.Path.cwd().parent\n"
            "(root/'tools/invoked').write_text('yes')\n"
            "case=os.environ.get('RELEASE_TEST_CASE', '')\n"
            "if case=='fail': sys.exit(42)\n"
            "apk=root/'client/build/app/outputs/flutter-apk/app-release.apk'\n"
            "apk.parent.mkdir(parents=True, exist_ok=True)\n"
            "apk.write_bytes(b'new fixture apk')\n"
            "if case in ('mutate', 'commit'):\n"
            "    with (root/'client/pubspec.yaml').open('a') as f: f.write('# changed during build\\n')\n"
            "if case=='commit':\n"
            "    subprocess.run(['git','add','.'],cwd=root,check=True)\n"
            "    subprocess.run(['git','commit','-qm','changed'],cwd=root,check=True)\n")
        (self.tools / "aapt.cmd").write_text("@echo off\necho package: versionCode='1706' versionName='1.7.3'\n")
        (self.tools / "apksigner.cmd").write_text("@echo off\nexit /b 0\n")
        self.output = self.client / "release-artifacts"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True, stderr=subprocess.PIPE)

    def build(self, case=""):
        env = dict(os.environ, RELEASE_TEST_CASE=case)
        env["PATH"] = str(self.tools) + os.pathsep + env["PATH"]
        return subprocess.run([shutil.which("pwsh") or "powershell", "-NoProfile", "-File",
            str(self.client / "scripts/build_release.ps1")], env=env, capture_output=True,
            text=True, encoding="utf-8", errors="replace")

    def test_clean_build_records_commit(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.output / "release-manifest.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["source_commit"], self.commit)
        self.assertEqual(manifest["version"], "1.7.3+1706")
        self.assertEqual((self.output / "shenliyuan-release.apk").read_bytes(), b"new fixture apk")

    def test_dirty_source_blocks_before_flutter(self):
        (self.root / "untracked.txt").write_text("uncommitted source")
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean working tree", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_failed_build_does_not_deliver_old_apk(self):
        stale = self.client / "build/app/outputs/flutter-apk/app-release.apk"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"stale")
        result = self.build("fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build failed", result.stderr)
        self.assertFalse((self.output / "shenliyuan-release.apk").exists())

    def test_source_changed_during_build_is_rejected(self):
        result = self.build("mutate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean working tree", result.stderr)
        self.assertFalse((self.output / "release-manifest.json").exists())

    def test_commit_changed_during_build_is_rejected(self):
        result = self.build("commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source commit changed", result.stderr)
        self.assertFalse((self.output / "release-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
