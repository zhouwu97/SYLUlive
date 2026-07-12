#!/bin/sh
set -eu

LETSENCRYPT_LIVE_DIR=${PAPER_STORAGE_LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live/sylulive.online}

has_lets_encrypt_certificate() {
    [ -f "$LETSENCRYPT_LIVE_DIR/fullchain.pem" ] && [ -f "$LETSENCRYPT_LIVE_DIR/privkey.pem" ]
}

render_nginx_config() {
    nginx_template=$1
    nginx_output=$2
    if has_lets_encrypt_certificate; then
        tls_certificate=$LETSENCRYPT_LIVE_DIR/fullchain.pem
        tls_certificate_key=$LETSENCRYPT_LIVE_DIR/privkey.pem
    else
        tls_certificate=/etc/ssl/certs/ssl-cert-snakeoil.pem
        tls_certificate_key=/etc/ssl/private/ssl-cert-snakeoil.key
    fi
    escaped_certificate=$(printf '%s' "$tls_certificate" | sed 's/[&|]/\\&/g')
    escaped_certificate_key=$(printf '%s' "$tls_certificate_key" | sed 's/[&|]/\\&/g')
    sed \
        -e "s|__PAPER_STORAGE_TLS_CERTIFICATE__|$escaped_certificate|g" \
        -e "s|__PAPER_STORAGE_TLS_CERTIFICATE_KEY__|$escaped_certificate_key|g" \
        "$nginx_template" > "$nginx_output"
}

if [ "${1:-}" = "--render-nginx" ]; then
    if [ "$#" -ne 3 ]; then
        echo "用法: install.sh --render-nginx 模板路径 输出路径" >&2
        exit 2
    fi
    render_nginx_config "$2" "$3"
    exit 0
fi

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

nginx_candidate=$(mktemp /etc/nginx/nginx.conf.sylg-candidate.XXXXXX)
nginx_previous=$(mktemp /etc/nginx/nginx.conf.sylg-previous.XXXXXX)
cleanup_nginx_temporary_files() {
    rm -f "$nginx_candidate" "$nginx_previous"
}
trap cleanup_nginx_temporary_files EXIT HUP INT TERM

render_nginx_config "$SCRIPT_DIR/nginx.conf" "$nginx_candidate"
chown root:root "$nginx_candidate"
chmod 0644 "$nginx_candidate"
if ! nginx -t -c "$nginx_candidate"; then
    echo "新 Nginx 配置校验失败，保留当前配置" >&2
    exit 1
fi
cp -p /etc/nginx/nginx.conf "$nginx_previous"
mv -f "$nginx_candidate" /etc/nginx/nginx.conf
if ! nginx -t; then
    cp -p "$nginx_previous" /etc/nginx/nginx.conf
    nginx -t || true
    echo "安装后的 Nginx 配置校验失败，已恢复上一版" >&2
    exit 1
fi

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
systemctl enable nginx paper-storage
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
else
    systemctl start nginx
fi

systemctl enable --now certbot.timer
if has_lets_encrypt_certificate; then
    echo "检测到现有 Let's Encrypt 证书，保留证书并跳过重复签发。"
elif [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
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
