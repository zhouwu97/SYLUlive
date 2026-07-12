#!/bin/sh
set -eu

# Ubuntu 24.04 独立试卷文件服务器幂等安装脚本。
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行此脚本" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BINARY_SOURCE=${PAPER_STORAGE_BINARY:-"$SCRIPT_DIR/../../server/dist/paper-storage"}

if [ ! -f "$BINARY_SOURCE" ]; then
    echo "未找到文件服务二进制：$BINARY_SOURCE" >&2
    echo "请先构建 Linux 二进制，或通过 PAPER_STORAGE_BINARY 指定路径" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nginx ufw certbot python3-certbot-nginx ssl-cert openssl ca-certificates curl

if ! id paper-storage >/dev/null 2>&1; then
    useradd --system --home-dir /opt/sylg-paper-storage --shell /usr/sbin/nologin paper-storage
fi

install -d -o root -g paper-storage -m 0750 /opt/sylg-paper-storage /opt/sylg-paper-storage/bin
install -d -o paper-storage -g paper-storage -m 0700 \
    /opt/sylg-paper-storage/data \
    /opt/sylg-paper-storage/data/exam-papers \
    /opt/sylg-paper-storage/data/exam-papers/.trash
chmod 0700 \
    /opt/sylg-paper-storage/data \
    /opt/sylg-paper-storage/data/exam-papers \
    /opt/sylg-paper-storage/data/exam-papers/.trash
install -o root -g paper-storage -m 0750 "$BINARY_SOURCE" /opt/sylg-paper-storage/bin/paper-storage

if [ ! -e /etc/sylg-paper-storage.env ]; then
    install -o root -g root -m 0600 "$SCRIPT_DIR/paper-storage.env.example" /etc/sylg-paper-storage.env
else
    chown root:root /etc/sylg-paper-storage.env
    chmod 0600 /etc/sylg-paper-storage.env
fi

install -o root -g root -m 0644 "$SCRIPT_DIR/paper-storage.service" /etc/systemd/system/paper-storage.service
if [ -f /etc/nginx/nginx.conf ] && [ ! -f /etc/nginx/nginx.conf.pre-sylg-paper-storage ]; then
    cp -p /etc/nginx/nginx.conf /etc/nginx/nginx.conf.pre-sylg-paper-storage
fi
install -o root -g root -m 0644 "$SCRIPT_DIR/nginx.conf" /etc/nginx/nginx.conf

# Nginx 工作进程与文件服务使用同一用户，避免放宽 PDF 的 0600 权限。
for directory in /var/lib/nginx /var/lib/nginx/body /var/lib/nginx/proxy /var/lib/nginx/fastcgi /var/lib/nginx/uwsgi /var/lib/nginx/scgi; do
    install -d -o paper-storage -g paper-storage -m 0700 "$directory"
done

# 已有 Swap 不足时新增专用文件，不停用、缩小或覆盖现有 Swap。
swap_target_kib=2097152
swap_current_kib=$(awk 'NR > 1 { total += $3 } END { print total + 0 }' /proc/swaps)
if [ "$swap_current_kib" -lt "$swap_target_kib" ]; then
    swap_path=/swapfile
    if [ -e "$swap_path" ] || grep -qs '^/swapfile ' /proc/swaps; then
        swap_path=/swapfile-sylg-paper-storage
    fi
    if [ ! -e "$swap_path" ]; then
        if [ "$swap_path" = /swapfile ]; then
            fallocate -l 2G /swapfile
        else
            fallocate -l 2G "$swap_path"
        fi
        chmod 0600 "$swap_path"
        mkswap "$swap_path" >/dev/null
    fi
    if ! grep -qs "^$swap_path " /proc/swaps; then
        if [ "$swap_path" = /swapfile ]; then
            swapon /swapfile
        else
            swapon "$swap_path"
        fi
    fi
    if ! grep -qsF "$swap_path none swap sw 0 0" /etc/fstab; then
        printf '%s\n' "$swap_path none swap sw 0 0" >> /etc/fstab
    fi
fi

install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
if [ ! -f /etc/systemd/journald.conf.d/sylg-paper-storage.conf ] || \
   ! grep -qs '^MaxRetentionSec=14day$' /etc/systemd/journald.conf.d/sylg-paper-storage.conf; then
    printf '%s\n' '[Journal]' 'MaxRetentionSec=14day' > /etc/systemd/journald.conf.d/sylg-paper-storage.conf
    chmod 0644 /etc/systemd/journald.conf.d/sylg-paper-storage.conf
    systemctl restart systemd-journald
fi
journalctl --vacuum-time=14d >/dev/null

# 必须先放行当前 SSH 端口，再启用防火墙，避免远程会话被锁死。
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl daemon-reload
nginx -t
systemctl enable nginx paper-storage
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl start nginx
fi

if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
    certbot --nginx --non-interactive --agree-tos --redirect \
        --email "$LETSENCRYPT_EMAIL" \
        -d sylulive.online -d www.sylulive.online
    nginx -t
    systemctl reload nginx
else
    echo "未设置 LETSENCRYPT_EMAIL；当前仅部署临时证书，请签发正式证书后再开放流量。"
fi

if grep -qs 'CHANGE_ME_' /etc/sylg-paper-storage.env; then
    echo "请生成两把不同密钥并更新 /etc/sylg-paper-storage.env，然后重新运行脚本。"
else
    systemctl restart paper-storage
    curl -fsS --max-time 10 http://127.0.0.1:8081/healthz >/dev/null
fi
