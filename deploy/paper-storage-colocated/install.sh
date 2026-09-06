#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行此脚本" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BINARY_SOURCE=${PAPER_STORAGE_BINARY:-"$SCRIPT_DIR/../../server/dist/paper-storage"}
DOMAIN=${PAPER_STORAGE_DOMAIN:-paper.sylulive.online}

case "$DOMAIN" in
    ''|*[!A-Za-z0-9.-]*|.*|*..*|*.)
        echo "PAPER_STORAGE_DOMAIN 无效" >&2
        exit 1
        ;;
esac
if [ ! -f "$BINARY_SOURCE" ] || [ -L "$BINARY_SOURCE" ]; then
    echo "未找到可信的 Linux 文件服务二进制：$BINARY_SOURCE" >&2
    exit 1
fi
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]; then
    echo "未找到 $DOMAIN 的 TLS 证书，拒绝修改 Nginx site" >&2
    exit 1
fi
command -v nginx >/dev/null 2>&1 || {
    echo "未安装 Nginx，请先完成主服务器 Nginx 基础安装" >&2
    exit 1
}
if ! grep -Eq 'include[[:space:]]+/etc/nginx/sites-enabled/\*;' /etc/nginx/nginx.conf; then
    echo "当前 Nginx 未启用 sites-enabled，拒绝按同机 site 方式安装" >&2
    exit 1
fi

if ! id paper-storage >/dev/null 2>&1; then
    useradd --system --home-dir /opt/sylg-paper-storage --shell /usr/sbin/nologin paper-storage
fi
install -d -o root -g paper-storage -m 0750 /opt/sylg-paper-storage /opt/sylg-paper-storage/bin
install -d -o paper-storage -g paper-storage -m 0700 \
    /opt/sylg-paper-storage/data \
    /opt/sylg-paper-storage/data/exam-papers \
    /opt/sylg-paper-storage/data/exam-papers/.pending \
    /opt/sylg-paper-storage/data/exam-papers/.sessions \
    /opt/sylg-paper-storage/data/exam-papers/.trash

if [ ! -e /etc/sylg-paper-storage.env ]; then
    install -o root -g root -m 0600 "$SCRIPT_DIR/paper-storage.env.example" /etc/sylg-paper-storage.env
else
    chown root:root /etc/sylg-paper-storage.env
    chmod 0600 /etc/sylg-paper-storage.env
fi
install -o root -g root -m 0644 "$SCRIPT_DIR/paper-storage.service" /etc/systemd/system/paper-storage.service

site_target=/etc/nginx/sites-available/paper-storage
site_enabled=/etc/nginx/sites-enabled/paper-storage
site_candidate=$(mktemp /etc/nginx/sites-available/paper-storage.XXXXXX)
site_previous=$(mktemp /etc/nginx/sites-available/paper-storage.previous.XXXXXX)
site_existed=0
site_enabled_existed=0
trap 'rm -f "$site_candidate" "$site_previous"' EXIT HUP INT TERM
sed "s/__PAPER_STORAGE_DOMAIN__/$DOMAIN/g" "$SCRIPT_DIR/nginx-site.conf" > "$site_candidate"
if [ -L "$site_target" ] || { [ -e "$site_target" ] && [ ! -f "$site_target" ]; }; then
    echo "Nginx site 目标不是普通文件，拒绝覆盖：$site_target" >&2
    exit 1
fi
if [ -L "$site_enabled" ]; then
    if [ "$(readlink "$site_enabled")" != "$site_target" ]; then
        echo "Nginx site 链接指向未知目标，拒绝覆盖：$site_enabled" >&2
        exit 1
    fi
    site_enabled_existed=1
elif [ -e "$site_enabled" ]; then
    echo "Nginx site 启用项不是符号链接，拒绝覆盖：$site_enabled" >&2
    exit 1
fi
if [ -f "$site_target" ] && [ ! -L "$site_target" ]; then
    cp -p "$site_target" "$site_previous"
    site_existed=1
fi
install -o root -g root -m 0644 "$site_candidate" "$site_target"
ln -sfn "$site_target" "$site_enabled"
if ! nginx -t; then
    rm -f "$site_enabled"
    if [ "$site_existed" -eq 1 ]; then
        cp -p "$site_previous" "$site_target"
        if [ "$site_enabled_existed" -eq 1 ]; then
            ln -s "$site_target" "$site_enabled"
        fi
    else
        rm -f "$site_target"
    fi
    nginx -t || true
    echo "Nginx site 校验失败，已恢复安装前状态" >&2
    exit 1
fi

binary_target=/opt/sylg-paper-storage/bin/paper-storage
binary_candidate=/opt/sylg-paper-storage/bin/paper-storage.new
install -o root -g paper-storage -m 0755 "$BINARY_SOURCE" "$binary_candidate"
if [ -f "$binary_target" ] && [ ! -f "$binary_target.bak" ]; then
    cp -p "$binary_target" "$binary_target.bak"
fi
mv -f "$binary_candidate" "$binary_target"

systemctl daemon-reload
systemctl enable paper-storage
if grep -qs 'CHANGE_ME_' /etc/sylg-paper-storage.env; then
    echo "服务文件已安装；请先写入两把不同的随机密钥，再启动 paper-storage。"
    exit 0
fi
systemctl restart paper-storage
curl -fsS http://127.0.0.1:8081/healthz >/dev/null
systemctl reload nginx
