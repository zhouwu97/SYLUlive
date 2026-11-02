"""Read-only bot-management release smoke test. Never sends an account token."""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args()
    origin = args.origin.rstrip("/")
    parsed = urlparse(origin)
    if parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password:
        parser.error("origin must contain only scheme, hostname and optional port")
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}):
        parser.error("HTTPS required except on loopback")
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        parser.error("sha must be an immutable full Git SHA")

    def read(path):
        try:
            response = urllib.request.urlopen(origin + path, timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            if urlparse(response.url).netloc != parsed.netloc:
                raise ValueError("unexpected redirect origin")
            body = response.read(16385)
            if len(body) > 16384:
                raise ValueError("unexpected response size")
            if "application/json" not in response.headers.get("Content-Type", ""):
                raise ValueError("JSON route contract missing")
            return response.status, json.loads(body)

    code, version = read("/version")
    if code != 200 or version.get("git_sha") != args.sha:
        raise ValueError("running SHA does not match candidate")
    if version.get("capabilities", {}).get("managed_bot_v1") is not True:
        raise ValueError("managed_bot_v1 is not enabled")
    for path in ("/api/connected-apps/bot", "/api/integrations/v1/bot/policy"):
        status, payload = read(path)
        if status != 401 or not isinstance(payload, dict):
            raise ValueError("authentication contract failed at " + path)
    print(json.dumps({"passed": True, "git_sha": args.sha, "managed_bot_v1": True, "protected_routes": 2}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        print(json.dumps({"passed": False, "reason": str(error)}))
        sys.exit(1)
