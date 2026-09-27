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
        (self.tools / "apksigner.cmd").write_text(
            "@echo off\n"
            "if \"%1\"==\"verify\" if \"%2\"==\"--print-certs\" "
            "echo Signer #1 certificate SHA-256 digest: A3:67:48:6B:8B:5D:5E:EB:F6:7D:28:49:80:9C:B9:B0:9C:5C:3E:4D:C9:0D:80:15:13:4A:F4:16:07:7E:FB:9E:^^& exit /b 0\n"
            "exit /b 0\n")
        self.output = self.client / "release-artifacts"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True, stderr=subprocess.PIPE)

    def build(self, case="", allow_candidate=True):
        env = dict(os.environ, RELEASE_TEST_CASE=case)
        env["PATH"] = str(self.tools) + os.pathsep + env["PATH"]
        command = [shutil.which("pwsh") or "powershell", "-NoProfile", "-File",
            str(self.client / "scripts/build_release.ps1")]
        if allow_candidate:
            command.append("-AllowCandidateBuild")
        return subprocess.run(command, env=env, capture_output=True,
            text=True, encoding="utf-8", errors="replace")

    def build_with_env(self, values):
        env = dict(os.environ, **values)
        env["PATH"] = str(self.tools) + os.pathsep + env["PATH"]
        return subprocess.run([shutil.which("pwsh") or "powershell", "-NoProfile", "-File",
            str(self.client / "scripts/build_release.ps1")], env=env, capture_output=True,
            text=True, encoding="utf-8", errors="replace")

    def build_with_workflow_fixture(self, *, ci_conclusion="success",
                                    missing_pip_audit=False,
                                    failed_pip_audit=False,
                                    release_decision="partial"):
        ci_jobs = [
            {"name": name, "status": "completed", "conclusion": "success"}
            for name in (
                "server-format", "server", "postgres-integration",
                "migration-upgrade", "edu-service", "rag-service", "client",
                "pgvector-integration", "client-platform-boundary", "release-script",
            )
        ]
        security_jobs = [
            {"name": "Secret scan", "status": "completed", "conclusion": "success"},
            {"name": "Go vulnerability scan", "status": "completed", "conclusion": "success"},
            {"name": "Python dependency audit (python-rag-service, requirements.txt)",
             "status": "completed", "conclusion": "success"},
            {"name": "Python dependency audit (python-edu-service, requirements.txt)",
             "status": "completed", "conclusion": "success"},
        ]
        if missing_pip_audit:
            security_jobs.pop()
        elif failed_pip_audit:
            security_jobs[-1]["conclusion"] = "failure"
        fixture = {
            "ci": {
                "id": 101,
                "repository": {"full_name": "owner/repo"},
                "head_sha": self.commit,
                "path": ".github/workflows/ci.yml",
                "status": "completed",
                "conclusion": ci_conclusion,
            },
            "ci_jobs": ci_jobs,
            "security": {
                "id": 202,
                "repository": {"full_name": "owner/repo"},
                "head_sha": self.commit,
                "path": ".github/workflows/security.yml",
                "status": "completed",
                "conclusion": "success",
            },
            "security_jobs": security_jobs,
        }
        fixture_path = self.tools / "workflow-fixture.json"
        fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
        wrapper_path = self.tools / "build_with_workflow_fixture.ps1"
        fixture_literal = str(fixture_path).replace("'", "''")
        script_literal = str(self.client / "scripts/build_release.ps1").replace("'", "''")
        wrapper_path.write_text(
            f"$data = Get-Content -Raw -LiteralPath '{fixture_literal}' | ConvertFrom-Json\n"
            "function Invoke-RestMethod {\n"
            "    param([string] $Uri, [string] $Method, [hashtable] $Headers)\n"
            "    if ($Uri -match '/actions/runs/101/jobs') { return [pscustomobject]@{ jobs = $data.ci_jobs } }\n"
            "    if ($Uri -match '/actions/runs/202/jobs') { return [pscustomobject]@{ jobs = $data.security_jobs } }\n"
            "    if ($Uri -match '/actions/runs/101$') { return $data.ci }\n"
            "    if ($Uri -match '/actions/runs/202$') { return $data.security }\n"
            "    throw \"Unexpected fixture URL: $Uri\"\n"
            "}\n"
            f"& '{script_literal}' -AllowCandidateBuild\n"
            "exit $LASTEXITCODE\n",
            encoding="utf-8",
        )
        env = dict(
            os.environ,
            RELEASE_CI_RUN_ID="101",
            RELEASE_SECURITY_RUN_ID="202",
            RELEASE_CI_REPOSITORY="owner/repo",
            RELEASE_DECISION=release_decision,
        )
        env["PATH"] = str(self.tools) + os.pathsep + env["PATH"]
        return subprocess.run(
            [shutil.which("pwsh") or "powershell", "-NoProfile", "-File", str(wrapper_path)],
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    def test_clean_build_records_commit(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.output / "release-manifest.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["source_commit"], self.commit)
        self.assertEqual(manifest["version"], "1.7.3+1706")
        self.assertEqual(manifest["release_decision"], "partial")
        self.assertEqual(manifest["evidence_status"], "unverified")
        self.assertIsNone(manifest["security_workflow_status"])
        self.assertEqual(manifest["security_evidence_status"], "unverified")
        self.assertEqual(manifest["gitleaks_status"], "unknown")
        self.assertEqual((self.output / "shenliyuan-candidate.apk").read_bytes(), b"new fixture apk")
        self.assertTrue(manifest["candidate"])

    def test_dirty_source_blocks_before_flutter(self):
        (self.client / "untracked.txt").write_text("uncommitted source")
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean App sources", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_failed_build_does_not_deliver_old_apk(self):
        stale = self.client / "build/app/outputs/flutter-apk/app-release.apk"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"stale")
        result = self.build("fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build failed", result.stderr)
        self.assertFalse((self.output / "shenliyuan-release.apk").exists())

    def test_passed_ci_status_requires_verifiable_run_id(self):
        result = self.build_with_env({"RELEASE_CI_STATUS": "passed"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GitHub Actions run id", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_default_build_requires_explicit_candidate_switch(self):
        result = self.build(allow_candidate=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AllowCandidateBuild", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_passed_release_requires_security_and_ci_evidence(self):
        result = self.build_with_env({"RELEASE_DECISION": "passed"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires verified release evidence", result.stderr)
        self.assertIn("security required jobs", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_workflow_fixture_requires_both_python_audits(self):
        result = self.build_with_workflow_fixture(release_decision="passed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.output / "release-manifest.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["dependency_audit_status"], "success")
        self.assertEqual(manifest["gitleaks_status"], "success")
        self.assertTrue(manifest["security_required_jobs_passed"])
        self.assertEqual(manifest["security_workflow_status"], "completed")
        self.assertEqual(manifest["security_evidence_status"], "verified")
        self.assertEqual(manifest["artifact"], "shenliyuan-release.apk")

    def test_missing_python_audit_blocks_formal_release(self):
        result = self.build_with_workflow_fixture(
            missing_pip_audit=True,
            release_decision="passed",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("security required jobs", result.stderr)
        self.assertIn("dependency audit", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_failed_python_audit_blocks_formal_release(self):
        result = self.build_with_workflow_fixture(
            failed_pip_audit=True,
            release_decision="passed",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("security required jobs", result.stderr)
        self.assertIn("dependency audit", result.stderr)
        self.assertFalse((self.tools / "invoked").exists())

    def test_failed_workflow_with_verified_app_jobs_keeps_statuses_separate(self):
        result = self.build_with_workflow_fixture(
            ci_conclusion="failure",
            release_decision="partial",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.output / "release-manifest.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(manifest["workflow_conclusion"], "failure")
        self.assertEqual(manifest["evidence_status"], "verified")
        self.assertTrue(manifest["ci_verified"])
        self.assertTrue(manifest["app_release_checks"])
        self.assertEqual(manifest["release_decision"], "partial")

    def test_source_changed_during_build_is_rejected(self):
        result = self.build("mutate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean App sources", result.stderr)
        self.assertFalse((self.output / "release-manifest.json").exists())

    def test_commit_changed_during_build_is_rejected(self):
        result = self.build("commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Source commit changed", result.stderr)
        self.assertFalse((self.output / "release-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
