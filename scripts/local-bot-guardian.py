"""Windows user-session supervisor for the locally installed QQ bot.

Uses fixed loopback endpoints. State contains only health codes, times and owned
process identities. It never sends messages, calls a model or changes grants.
"""
import argparse
import contextlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import subprocess
import time

import httpx
import psutil


def write_json(path, data):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=True, indent=2), encoding="utf-8")
    temporary.replace(path)


class Recovery:
    """Three consecutive failures, exponential backoff, at most three/hour."""
    def __init__(self, state):
        self.state = state

    def observe(self, name, healthy, now, *, repairable=True):
        item = self.state.setdefault(name, {"failures": 0, "attempts": [], "next_at": 0})
        item["attempts"] = [t for t in item["attempts"] if now - t < 3600]
        item["failures"] = 0 if healthy else min(1000, item["failures"] + 1)
        if healthy or not repairable or item["failures"] < 3:
            return False
        return self.reserve(name, now)

    def reserve(self, name, now):
        item = self.state.setdefault(name, {"failures": 0, "attempts": [], "next_at": 0})
        item["attempts"] = [t for t in item["attempts"] if now - t < 3600]
        if now < item["next_at"] or len(item["attempts"]) >= 3:
            return False
        item["attempts"].append(now)
        item["next_at"] = now + min(1800, 120 * 2 ** (len(item["attempts"]) - 1))
        return True


class Guardian:
    def __init__(self, root, *, now=time.time):
        self.root, self.now = root.resolve(), now
        self.directory = self.root / "guardian"
        self.directory.mkdir(exist_ok=True)
        self.state_path = self.directory / "state.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}
        self.recovery = Recovery(self.state.setdefault("recovery", {}))
        self.access = json.loads((root / "secrets/local-access.json").read_text(encoding="utf-8-sig"))
        self.target = json.loads((root / "bot-target.json").read_text(encoding="utf-8-sig"))
        self.python = root / "AstrBot/.venv/Scripts/python.exe"
        self.log = logging.getLogger("guardian")

    def _owned(self, process, service):
        try:
            command = process.cmdline()
            exe = Path(process.exe())
            if service == "snowluma":
                return (exe == self.root / "SnowLuma/node.exe" and "index.mjs" in command
                        and Path(process.cwd()) == self.root / "SnowLuma")
            launcher = self.root / "AstrBot/.venv/Scripts/astrbot.exe"
            return str(launcher).casefold() in {v.casefold() for v in command} and "run" in command
        except (psutil.Error, OSError):
            return False

    def processes(self, service):
        return [p for p in psutil.process_iter() if self._owned(p, service)]

    def start_or_restart(self, service):
        # Check exact executable/arguments/cwd before touching any process.
        family = self.processes(service)
        for process in family:
            try:
                children = process.children(recursive=True)
                for child in reversed(children):
                    if self._owned(child, service):
                        child.terminate()
                if self._owned(process, service):
                    process.terminate()
            except psutil.Error:
                pass
        _, alive = psutil.wait_procs(family, timeout=5)
        if alive:
            return "stop_pending"
        env = os.environ.copy()
        env.update(PYTHONUTF8="1", PYTHONUNBUFFERED="1")
        if service == "astrbot":
            args = [str(self.root / "AstrBot/.venv/Scripts/astrbot.exe"), "run"]
            cwd = self.root / "AstrBot"
        else:
            args = [str(self.root / "SnowLuma/node.exe"), "index.mjs"]
            cwd = self.root / "SnowLuma"
            env.update(SNOWLUMA_WEBUI_HOST="127.0.0.1", SNOWLUMA_UPDATE_CHECK="0", SNOWLUMA_PACKET_TIMEOUT_MS="60000")
            env.pop("SNOWLUMA_HOOK_AUTOLOAD", None)
        for suffix in ("stdout", "stderr"):
            path = self.directory / f"{service}.{suffix}.log"
            if path.exists() and path.stat().st_size > 2_000_000:
                path.replace(path.with_suffix(".previous.log"))
        with open(self.directory / f"{service}.stdout.log", "ab") as out, open(self.directory / f"{service}.stderr.log", "ab") as err:
            child = subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                     creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.state.setdefault("started", {})[service] = {"pid": child.pid, "created_at": psutil.Process(child.pid).create_time()}
        # Keep the existing maintenance entry compatible after guardian recovery.
        path = self.root / "services.json"
        tracked = json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
        tracked[service] = child.pid
        write_json(path, tracked)
        return "started"

    def reconnect(self):
        # connect-bot verifies the pinned PID, creation time and QQ executable.
        result = subprocess.run([str(self.python), str(self.root / "connect-bot.py")],
            cwd=self.root, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=55, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return "reconnected" if result.returncode == 0 else "verify_bot_login"

    def tick(self):
        now = self.now()
        result = {"checked_at": now, "services": {}, "actions": []}
        if (self.directory / "paused").exists():
            result["state"] = "paused"
            write_json(self.directory / "health.json", result)
            return result
        with httpx.Client(trust_env=False, timeout=6) as client:
            headers = {"Authorization": "Bearer " + self.access["astrbot_session_token"]}
            # The dashboard JWT can expire during long uptime. Re-authenticate
            # locally rather than restart a healthy bot or expose a new token.
            try:
                response = client.get("http://127.0.0.1:6185/api/v1/plugins", headers=headers)
                if response.status_code == 401:
                    login = client.post("http://127.0.0.1:6185/api/auth/login", json={
                        "username": self.access["astrbot_username"], "password": self.access["astrbot_password"]})
                    if login.status_code == 200 and login.json().get("status") == "ok":
                        self.access["astrbot_session_token"] = login.json()["data"]["token"]
                        headers = {"Authorization": "Bearer " + self.access["astrbot_session_token"]}
            except (httpx.HTTPError, ValueError, KeyError):
                pass
            astr_ok = snow_ok = False
            health = None
            for name, url, path, auth in [
                ("astrbot", "http://127.0.0.1:6185", "/api/v1/plugins", headers),
                ("snowluma", "http://127.0.0.1:5099", "/", {}),
            ]:
                repairable = True
                try:
                    response = client.get(url + path, headers=auth)
                    ok = response.status_code == 200
                    if response.status_code in (401, 403):
                        repairable = False  # Restart cannot repair an expired dashboard session.
                        code = "dashboard_login_required"
                    else:
                        code = "healthy" if ok else "http_unavailable"
                    if name == "astrbot" and ok:
                        plugin = next((p for p in response.json()["data"] if p["name"] == "astrbot_plugin_sylulive"), None)
                        result["plugin_active"] = bool(plugin and plugin["activated"])
                        # Intentional disable is respected; do not turn it on automatically.
                        if result["plugin_active"]:
                            h = client.get("http://127.0.0.1:6185/api/plug/astrbot_plugin_sylulive/runtime/health", headers=headers)
                            if h.status_code == 200:
                                body = h.json()
                                if "manager_alive" in body:
                                    health = body
                except (httpx.HTTPError, ValueError, KeyError):
                    ok, code = False, "unreachable"
                result["services"][name] = code
                if name == "astrbot": astr_ok = ok
                else: snow_ok = ok
                if self.recovery.observe(name, ok, now, repairable=repairable):
                    # If a foreign process owns the port, never start another service.
                    if not self.processes(name) and self.port_in_use(6185 if name == "astrbot" else 5099):
                        result["actions"].append(name + ":port_owned_elsewhere")
                    else:
                        result["actions"].append(name + ":" + self.start_or_restart(name))
            if health is not None:
                result["runtime"] = health
                task_ok = health.get("manager_alive") is True and health.get("discovery_age_seconds", 999) < 90 and not health.get("failed_workers")
                if self.recovery.observe("plugin_runtime", task_ok, now):
                    response = client.post("http://127.0.0.1:6185/api/v1/plugins/astrbot_plugin_sylulive/reload", headers=headers)
                    result["actions"].append("plugin_runtime:" + ("reloaded" if response.status_code == 200 and response.json().get("status") == "ok" else "reload_failed"))
            elif astr_ok and result.get("plugin_active"):
                result["runtime"] = {"state": "health_unavailable"}
            if snow_ok:
                try:
                    config = json.loads((self.root / f"SnowLuma/config/onebot_{self.target['uin']}.json").read_text(encoding="utf-8-sig"))
                    token = config["networks"]["httpServers"][0]["accessToken"]
                    one_headers = {"Authorization": "Bearer " + token}
                    status = client.post("http://127.0.0.1:3000/get_status", json={}, headers=one_headers).json()
                    identity = client.post("http://127.0.0.1:3000/get_login_info", json={}, headers=one_headers).json()
                    identity_ok = str(identity.get("data", {}).get("user_id")) == self.target["uin"]
                    online = identity_ok and status.get("data", {}).get("online") is True and status.get("data", {}).get("good") is True
                    result["qq"] = "online" if online else "verify_bot_login"
                except (httpx.HTTPError, ValueError, KeyError, IndexError, OSError):
                    online, identity_ok = False, True
                    result["qq"] = "bridge_unreachable"
                if self.recovery.observe("qq_bridge", online, now, repairable=identity_ok):
                    result["actions"].append("qq_bridge:" + self.reconnect())
                try:
                    login = client.post("http://127.0.0.1:5099/api/login", json={"password": self.access["snowluma_password"]})
                    login.raise_for_status()
                    connections = client.get("http://127.0.0.1:5099/api/connections", headers={
                        "Authorization": "Bearer " + login.json()["token"]}).json()["list"]
                    bot = next((p for p in connections if str(p["uin"]) == self.target["uin"]), {})
                    ws_ok = any(p.get("kind") == "wsClient" and p.get("name") == "astrbot" and p.get("status") == "ok" for p in bot.get("adapters", []))
                    result["qq_to_astrbot"] = "connected" if ws_ok else "disconnected"
                    if astr_ok and online and self.recovery.observe("reverse_websocket", ws_ok, now):
                        # Reuse the same SnowLuma budget; do not storm restarts.
                        if self.recovery.reserve("snowluma", now):
                            result["actions"].append("snowluma:" + self.start_or_restart("snowluma"))
                except (httpx.HTTPError, ValueError, KeyError):
                    result["qq_to_astrbot"] = "unknown"
            if astr_ok:
                try:
                    stats = client.get("http://127.0.0.1:6185/api/platform/stats", headers=headers).json()["data"]
                    platform = next(p for p in stats["platforms"] if p["id"] == "snowluma")
                    result["platform"] = platform["status"]
                except (httpx.HTTPError, ValueError, KeyError, StopIteration):
                    result["platform"] = "unknown"
        self.state["last_checked_at"] = now
        write_json(self.state_path, self.state)
        write_json(self.directory / "health.json", result)
        if result["actions"]:
            self.log.warning("recovery %s", ",".join(result["actions"]))
        return result

    @staticmethod
    def port_in_use(port):
        return any(c.laddr.port == port and c.status == psutil.CONN_LISTEN for c in psutil.net_connections(kind="tcp"))


@contextlib.contextmanager
def exclusive(directory):
    """OS lock released after a crash; never trust stale PID files."""
    import msvcrt
    with open(directory / "guardian.lock", "a+b") as handle:
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            yield False
            return
        try:
            yield True
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("D:/AI/QQ"))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    guardian = Guardian(args.root)
    handler = RotatingFileHandler(guardian.directory / "guardian.log", maxBytes=512_000, backupCount=3, encoding="utf-8")
    logging.basicConfig(level=logging.WARNING, handlers=[handler])
    with exclusive(guardian.directory) as acquired:
        if not acquired:
            return
        while True:
            try:
                result = guardian.tick()
                if args.once:
                    print(json.dumps(result))
            except Exception:
                # No exception text: SDK and HTTP errors may contain credentials.
                logging.getLogger("guardian").error("health_check_failed")
                if args.once:
                    raise SystemExit(1)
            if args.once:
                break
            time.sleep(30)


if __name__ == "__main__":
    main()
