#!/bin/sh
set -eu

DOMAIN=${PAPER_STORAGE_DOMAIN:-paper.sylulive.online}
systemctl is-active --quiet paper-storage
test "$(ss -lntH 'sport = :8081' | awk '{print $4}' | head -n 1)" = "127.0.0.1:8081"
curl -fsS http://127.0.0.1:8081/healthz
test "$(curl -sS -o /dev/null -w '%{http_code}' "https://$DOMAIN/v1/files/random.pdf")" = "401"
test "$(curl -sS -o /dev/null -w '%{http_code}' "https://$DOMAIN/internal/v1/maintenance")" = "404"
echo "paper-storage 同机部署基础验收通过"
