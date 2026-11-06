import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import httpx
import pytest

spec = importlib.util.spec_from_file_location("guardian", Path(__file__).with_name("local-bot-guardian.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_recovery_waits_for_consecutive_failures_and_limits_restart_storm():
    recovery = module.Recovery({})
    assert not recovery.observe("astrbot", False, 100)
    assert not recovery.observe("astrbot", False, 130)
    assert not recovery.observe("astrbot", True, 160)
    assert not recovery.observe("astrbot", False, 190)
    assert not recovery.observe("astrbot", False, 220)
    assert recovery.observe("astrbot", False, 250)
    assert not recovery.observe("astrbot", False, 280)
    assert recovery.observe("astrbot", False, 370)
    assert recovery.observe("astrbot", False, 610)
    assert not recovery.observe("astrbot", False, 1200)
    # Bad credentials and suspended services must not consume recovery budgets.
    assert not recovery.observe("auth", False, 1000, repairable=False)
    assert recovery.state["auth"]["attempts"] == []
    assert not recovery.reserve("astrbot", 1201)
    assert recovery.reserve("astrbot", 4300)


def fixture(tmp_path):
    (tmp_path / "secrets").mkdir()
    (tmp_path / "secrets/local-access.json").write_text(json.dumps({
        "astrbot_session_token": "synthetic-old", "astrbot_username": "test", "astrbot_password": "secret-test", "snowluma_password": "secret-test"}))
    (tmp_path / "bot-target.json").write_text(json.dumps({"uin": "123", "pid": 1}))
    directory = tmp_path / "SnowLuma/config"
    directory.mkdir(parents=True)
    (directory / "onebot_123.json").write_text(json.dumps({"networks": {"httpServers": [{"accessToken": "synthetic-onebot"}]}}))
    return module.Guardian(tmp_path, now=lambda: 1000)


def response(request, *, auth_failed=False, identity="123", ws=True, health=None):
    path = request.url.path
    if path == "/api/v1/plugins":
        if auth_failed or request.headers.get("authorization") == "Bearer synthetic-old":
            return httpx.Response(401)
        return httpx.Response(200, json={"data": [{"name": "astrbot_plugin_sylulive", "activated": True}]})
    if path == "/api/auth/login":
        return httpx.Response(403) if auth_failed else httpx.Response(200, json={"status": "ok", "data": {"token": "synthetic-new"}})
    if path.endswith("/runtime/health"):
        return httpx.Response(200, json=health or {"manager_alive": True, "discovery_age_seconds": 0, "failed_workers": 0})
    if path == "/get_status":
        return httpx.Response(200, json={"data": {"online": True, "good": True}})
    if path == "/get_login_info":
        return httpx.Response(200, json={"data": {"user_id": identity}})
    if path == "/api/login":
        return httpx.Response(200, json={"token": "synthetic-snow"})
    if path == "/api/connections":
        return httpx.Response(200, json={"list": [{"uin": "123", "adapters": [{"kind": "wsClient", "name": "astrbot", "status": "ok" if ws else "error"}]}]})
    if path == "/api/platform/stats":
        return httpx.Response(200, json={"data": {"platforms": [{"id": "snowluma", "status": "running"}]}})
    return httpx.Response(200, json={"status": "ok"})


@pytest.mark.parametrize("auth_failed", [False, True])
def test_expired_jwt_reauthenticates_without_restarting_or_leaking_secrets(tmp_path, monkeypatch, auth_failed):
    guardian = fixture(tmp_path)
    real_client = httpx.Client
    monkeypatch.setattr(module.httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(lambda r: response(r, auth_failed=auth_failed)), **kw))
    guardian.start_or_restart = Mock()
    for _ in range(4):
        result = guardian.tick()
    guardian.start_or_restart.assert_not_called()
    assert result["services"]["astrbot"] == ("dashboard_login_required" if auth_failed else "healthy")
    assert "synthetic" not in (guardian.directory / "health.json").read_text()
    assert "secret-test" not in (guardian.directory / "state.json").read_text()


def test_bridge_identity_mismatch_never_reconnects_another_account(tmp_path, monkeypatch):
    guardian = fixture(tmp_path)
    real_client = httpx.Client
    monkeypatch.setattr(module.httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(lambda r: response(r, identity="999")), **kw))
    guardian.reconnect = Mock()
    for _ in range(4): guardian.tick()
    guardian.reconnect.assert_not_called()


def test_disconnected_reverse_websocket_recovers_without_touching_astrbot(tmp_path, monkeypatch):
    guardian = fixture(tmp_path)
    real_client = httpx.Client
    monkeypatch.setattr(module.httpx, "Client", lambda **kw: real_client(transport=httpx.MockTransport(lambda r: response(r, ws=False)), **kw))
    guardian.start_or_restart = Mock(return_value="started")
    for _ in range(4): guardian.tick()
    guardian.start_or_restart.assert_called_once_with("snowluma")


def test_pause_is_effective_before_any_http_or_recovery(tmp_path, monkeypatch):
    guardian = fixture(tmp_path)
    (guardian.directory / "paused").touch()
    monkeypatch.setattr(module.httpx, "Client", Mock(side_effect=AssertionError("must not contact service")))
    assert guardian.tick()["state"] == "paused"


def test_process_identity_requires_exact_local_executable_and_arguments(tmp_path):
    guardian = fixture(tmp_path)
    process = Mock()
    process.exe.return_value = str(tmp_path / "SnowLuma/node.exe")
    process.cwd.return_value = str(tmp_path / "SnowLuma")
    process.cmdline.return_value = [str(tmp_path / "SnowLuma/node.exe"), "index.mjs"]
    assert guardian._owned(process, "snowluma")
    process.exe.return_value = "C:/unrelated/node.exe"
    assert not guardian._owned(process, "snowluma")
    process.exe.return_value = "C:/QQ/QQ.exe"
    assert not guardian._owned(process, "astrbot")


def test_isolated_process_exit_is_recovered_and_other_process_is_preserved(tmp_path, monkeypatch):
    """Exercise real termination/start with disposable sleepers, never the bot."""
    guardian = fixture(tmp_path)
    real_popen = subprocess.Popen
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    dead = real_popen([sys.executable, "-c", "import time; time.sleep(120)"], creationflags=flags)
    other = real_popen([sys.executable, "-c", "import time; time.sleep(120)"], creationflags=flags)
    started = []
    def replacement(args, **kwargs):
        assert args == [str(tmp_path / "SnowLuma/node.exe"), "index.mjs"]
        process = real_popen([sys.executable, "-c", "import time; time.sleep(120)"], creationflags=flags)
        started.append(process)
        return process
    monkeypatch.setattr(module.subprocess, "Popen", replacement)
    monkeypatch.setattr(guardian, "processes", lambda _: [module.psutil.Process(dead.pid)])
    monkeypatch.setattr(guardian, "_owned", lambda p, _: p.pid == dead.pid)
    try:
        assert guardian.start_or_restart("snowluma") == "started"
        assert dead.poll() is not None and other.poll() is None
        assert started[0].poll() is None
        assert guardian.state["started"]["snowluma"]["pid"] == started[0].pid
        assert json.loads((tmp_path / "services.json").read_text())["snowluma"] == started[0].pid
    finally:
        for process in [dead, other, *started]:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
