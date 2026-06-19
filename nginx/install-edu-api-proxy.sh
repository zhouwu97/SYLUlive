#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-sylu.zhouwu.ccwu.cc}"
EDU_UPSTREAM="${EDU_UPSTREAM:-http://101.42.27.44:8000/}"
CONF_FILE="${CONF_FILE:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx is not installed or not in PATH" >&2
  exit 1
fi

if [ -z "$CONF_FILE" ]; then
  CONF_FILE="$(grep -RIl "server_name .*${DOMAIN}" /etc/nginx 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$CONF_FILE" ] || [ ! -f "$CONF_FILE" ]; then
  echo "Could not find nginx config for ${DOMAIN}." >&2
  echo "Run with CONF_FILE=/path/to/site.conf sudo -E bash $0" >&2
  exit 1
fi

if grep -q "location /edu-api/" "$CONF_FILE"; then
  echo "location /edu-api/ already exists in $CONF_FILE"
  nginx -t
  systemctl reload nginx
  exit 0
fi

backup="${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "$CONF_FILE" "$backup"

python3 - "$CONF_FILE" "$DOMAIN" "$EDU_UPSTREAM" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
domain = sys.argv[2]
upstream = sys.argv[3]
text = path.read_text()

block = f"""

    # Python edu service reverse proxy. Keeps browser requests on the HTTPS origin.
    location /edu-api/ {{
        proxy_pass {upstream};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 120s;
    }}
"""

server_re = re.compile(r"server\s*\{", re.M)
matches = list(server_re.finditer(text))
chosen = None

for match in matches:
    start = match.start()
    depth = 0
    end = None
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    if end is None:
        continue
    body = text[start : end + 1]
    if domain in body and ("listen 443" in body or "ssl" in body):
        chosen = (start, end)
        break

if chosen is None:
    for match in matches:
        start = match.start()
        depth = 0
        end = None
        for i in range(start, len(text)):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end is None:
            continue
        body = text[start : end + 1]
        if domain in body:
            chosen = (start, end)
            break

if chosen is None:
    raise SystemExit(f"Could not find a server block for {domain}")

start, end = chosen
new_text = text[:end] + block + "\n" + text[end:]
path.write_text(new_text)
PY

nginx -t
systemctl reload nginx

echo "Configured /edu-api/ in $CONF_FILE"
echo "Backup: $backup"
echo "Verify with: curl -sS https://${DOMAIN}/edu-api/health"
