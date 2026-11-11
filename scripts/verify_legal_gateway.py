"""Exercise the legal-document locations with a real, isolated Nginx process.

Usage: python scripts/verify_legal_gateway.py --nginx /path/to/nginx
Only the legal location is included; this does not validate an entire production
gateway, Linux-only file acceleration, TLS configuration or production state.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
CONFIGS = ("nginx/docker.conf", "nginx/sylulive-site-v5-deep-links.conf", "web/deploy/nginx.conf")


class Documents(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.document(True)

    def do_HEAD(self):
        self.document(False)

    def document(self, body):
        name = {"/terms": "terms.html", "/privacy": "privacy.html", "/extension/privacy": "extension-privacy.html"}.get(self.path.split("?")[0])
        if not name:
            self.send_error(404)
            return
        data = (ROOT / "server/static/legal" / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if body:
            self.wfile.write(data)

    def log_message(self, *_):
        pass


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def verify(binary: Path, baseline: str | None):
    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Documents)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    results = []
    try:
        for relative in CONFIGS:
            source = subprocess.check_output(["git", "show", f"{baseline}:{relative}"], cwd=ROOT).decode("utf-8") if baseline else (ROOT / relative).read_text(encoding="utf-8")
            location = re.search(r"location\s+~\s+\^/\(terms\|privacy(?:\|extension/privacy)?\)\$\s*\{[^{}]*\}", source)
            selected = location.group() if location else ""
            selected = selected.replace("http://server:8080", f"http://127.0.0.1:{upstream.server_port}").replace("http://127.0.0.1:8080", f"http://127.0.0.1:{upstream.server_port}")
            with tempfile.TemporaryDirectory(prefix="sylu-legal-gateway-") as work:
                directory = Path(work).resolve()
                if not directory.is_relative_to(Path(tempfile.gettempdir()).resolve()):
                    raise RuntimeError("Unexpected temporary directory")
                (directory / "logs").mkdir()
                (directory / "temp").mkdir()
                port = available_port()
                config = f"""daemon off;
master_process off;
error_log logs/error.log;
pid logs/nginx.pid;
events {{ worker_connections 32; }}
http {{
    access_log off;
    server {{
        listen 127.0.0.1:{port};
        {selected}
        location / {{ default_type text/html; return 200 '<h1>Homepage fallback</h1>'; }}
    }}
}}
"""
                (directory / "nginx.conf").write_text(config, encoding="utf-8")
                args = [str(binary), "-p", directory.as_posix() + "/", "-c", "nginx.conf"]
                checked = subprocess.run([*args, "-t"], capture_output=True, text=True, timeout=10)
                if checked.returncode:
                    raise RuntimeError(checked.stderr)
                flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
                with open(directory / "process.log", "w", encoding="utf-8") as log:
                    process = subprocess.Popen(args, stdout=log, stderr=log, creationflags=flags)
                    try:
                        deadline = time.monotonic() + 5
                        while True:
                            try:
                                with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=.5):
                                    break
                            except OSError:
                                if process.poll() is not None or time.monotonic() > deadline:
                                    raise RuntimeError("Isolated Nginx did not start")
                                time.sleep(.05)
                        for path, title in (("/terms", "沈理校园用户协议"), ("/privacy", "沈理校园隐私政策"), ("/extension/privacy", "沈理校园教务助手隐私说明")):
                            for method in ("GET", "HEAD"):
                                request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method)
                                with urllib.request.urlopen(request, timeout=3) as response:
                                    content = response.read().decode("utf-8")
                                    passed = response.status == 200 and response.headers.get_content_type() == "text/html" and (method == "HEAD" or f"<h1>{title}</h1>" in content)
                                    results.append({"config": relative, "path": path, "method": method, "passed": passed})
                    finally:
                        process.terminate()
                        process.wait(timeout=5)
    finally:
        upstream.shutdown()
        upstream.server_close()
        thread.join(timeout=2)
    print(json.dumps({"checks": results, "passed": all(row["passed"] for row in results)}, ensure_ascii=False, indent=2))
    return 0 if all(row["passed"] for row in results) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nginx", type=Path, required=True)
    parser.add_argument("--baseline-ref", help="Read an earlier revision to reproduce the fallback defect")
    options = parser.parse_args()
    raise SystemExit(verify(options.nginx.resolve(), options.baseline_ref))
