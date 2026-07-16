#!/bin/sh
set -eu

TLS_CERT_PATH_WAS_SET=${PAPER_STORAGE_TLS_CERT_PATH+x}
TLS_KEY_PATH_WAS_SET=${PAPER_STORAGE_TLS_KEY_PATH+x}
PUBLIC_IP=${PAPER_STORAGE_PUBLIC_IP:-139.196.148.174}
ACME_MODE=${PAPER_STORAGE_ACME_MODE:-auto}
TLS_CERT_PATH=${PAPER_STORAGE_TLS_CERT_PATH:-/etc/letsencrypt/live/$PUBLIC_IP/fullchain.pem}
TLS_KEY_PATH=${PAPER_STORAGE_TLS_KEY_PATH:-/etc/letsencrypt/live/$PUBLIC_IP/privkey.pem}
TLS_MIN_VALIDITY_SECONDS=${PAPER_STORAGE_TLS_MIN_VALIDITY_SECONDS:-86400}
SYSTEM_CA_BUNDLE=${PAPER_STORAGE_SYSTEM_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}
SSH_PORT=${SSH_PORT:-22}
SWAP_SIZE=${PAPER_STORAGE_SWAP_SIZE:-2G}
FSTAB_PATH=${PAPER_STORAGE_FSTAB:-/etc/fstab}
SWAPS_FILE=${PAPER_STORAGE_SWAPS_FILE:-/proc/swaps}

nginx_candidate=
nginx_previous=
swap_new=
fstab_new=
binary_candidate=

cleanup_temporary_files() {
    [ -z "$nginx_candidate" ] || rm -f "$nginx_candidate"
    [ -z "$nginx_previous" ] || rm -f "$nginx_previous"
    [ -z "$swap_new" ] || rm -f "$swap_new"
    [ -z "$fstab_new" ] || rm -f "$fstab_new"
    [ -z "$binary_candidate" ] || rm -f "$binary_candidate"
}
trap cleanup_temporary_files EXIT HUP INT TERM

validate_public_ip() {
    public_ip=$1
    old_ifs=$IFS
    IFS=.
    set -- $public_ip
    IFS=$old_ifs
    if [ "$#" -ne 4 ]; then
        echo "PAPER_STORAGE_PUBLIC_IP 必须是四段十进制 IPv4 地址" >&2
        return 1
    fi
    for octet in "$@"; do
        case "$octet" in
            ''|*[!0-9]*)
                echo "PAPER_STORAGE_PUBLIC_IP 必须是四段十进制 IPv4 地址" >&2
                return 1
                ;;
        esac
        if [ "${#octet}" -gt 3 ] || [ "$octet" -gt 255 ]; then
            echo "PAPER_STORAGE_PUBLIC_IP 的每段必须位于 0 到 255" >&2
            return 1
        fi
    done
    if [ "$public_ip" != "139.196.148.174" ] && \
       [ "${PAPER_STORAGE_ALLOW_TEST_IP:-0}" != "1" ]; then
        echo "正式文件服务器 IP 必须是 139.196.148.174" >&2
        return 1
    fi
}

validate_acme_mode() {
    case "$ACME_MODE" in
        auto|external) ;;
        *)
            echo "PAPER_STORAGE_ACME_MODE 只能是 auto 或 external" >&2
            return 1
            ;;
    esac
}

validate_tls_path() {
    tls_path=$1
    tls_label=$2
    if [ ! -f "$tls_path" ]; then
        echo "$tls_label 不存在或不是普通文件：$tls_path" >&2
        return 1
    fi
    if [ -L "$tls_path" ]; then
        resolved_path=$(readlink -f "$tls_path") || return 1
        case "$resolved_path" in
            "/etc/letsencrypt/archive/$PUBLIC_IP/"*) ;;
            *)
                echo "$tls_label 不得链接到受控证书目录之外：$tls_path" >&2
                return 1
                ;;
        esac
    fi
}

validate_tls_certificate() {
    validate_tls_path "$TLS_CERT_PATH" "TLS 证书"
    validate_tls_path "$TLS_KEY_PATH" "TLS 私钥"
    case "$TLS_MIN_VALIDITY_SECONDS" in
        ''|*[!0-9]*)
            echo "PAPER_STORAGE_TLS_MIN_VALIDITY_SECONDS 必须是非负整数" >&2
            return 1
            ;;
    esac
    openssl x509 -in "$TLS_CERT_PATH" -noout >/dev/null
    openssl pkey -in "$TLS_KEY_PATH" -noout >/dev/null
    cert_key_digest=$(openssl x509 -in "$TLS_CERT_PATH" -pubkey -noout | \
        openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)
    private_key_digest=$(openssl pkey -in "$TLS_KEY_PATH" -pubout -outform DER 2>/dev/null | \
        openssl dgst -sha256)
    if [ "$cert_key_digest" != "$private_key_digest" ]; then
        echo "TLS 证书与私钥不匹配" >&2
        return 1
    fi
    if ! openssl x509 -in "$TLS_CERT_PATH" -checkend "$TLS_MIN_VALIDITY_SECONDS" -noout; then
        echo "TLS 证书已过期或即将进入续期窗口" >&2
        return 1
    fi
    escaped_ip=$(printf '%s' "$PUBLIC_IP" | sed 's/\./\\./g')
    if ! openssl x509 -in "$TLS_CERT_PATH" -noout -ext subjectAltName | \
        grep -Eq "(^|[,[:space:]])IP Address:${escaped_ip}([,[:space:]]|$)"; then
        echo "TLS 证书 SAN 不包含 IP 地址 $PUBLIC_IP" >&2
        return 1
    fi
    if [ ! -f "$SYSTEM_CA_BUNDLE" ] || \
       ! openssl verify -CAfile "$SYSTEM_CA_BUNDLE" -untrusted "$TLS_CERT_PATH" "$TLS_CERT_PATH" >/dev/null; then
        echo "TLS 证书链不受系统信任" >&2
        return 1
    fi
}

validate_certbot_version() {
    certbot_version=$(certbot --version 2>&1 | awk '{ print $2 }')
    certbot_major=$(printf '%s' "$certbot_version" | cut -d. -f1)
    certbot_minor=$(printf '%s' "$certbot_version" | cut -d. -f2)
    case "$certbot_major:$certbot_minor" in
        *[!0-9:]*|:*)
            echo "无法识别 Certbot 版本：$certbot_version" >&2
            return 1
            ;;
    esac
    if [ "$certbot_major" -lt 5 ] || \
       { [ "$certbot_major" -eq 5 ] && [ "$certbot_minor" -lt 4 ]; }; then
        echo "IP 地址证书要求 Certbot 5.4 或更高版本，当前为 $certbot_version" >&2
        return 1
    fi
}

ensure_modern_certbot() {
    if command -v certbot >/dev/null 2>&1 && validate_certbot_version; then
        return 0
    fi
    echo "正在通过 Snap 安装支持 IP 证书的 Certbot。"
    snap install core
    snap refresh core
    snap install --classic certbot
    ln -sfn /snap/bin/certbot /usr/local/bin/certbot
    hash -r
    validate_certbot_version
}

render_nginx_config() {
    nginx_template=$1
    nginx_output=$2
    validate_public_ip "$PUBLIC_IP"
    validate_tls_certificate
    escaped_certificate=$(printf '%s' "$TLS_CERT_PATH" | sed 's/[&|]/\\&/g')
    escaped_certificate_key=$(printf '%s' "$TLS_KEY_PATH" | sed 's/[&|]/\\&/g')
    escaped_public_ip=$(printf '%s' "$PUBLIC_IP" | sed 's/[&|]/\\&/g')
    sed \
        -e "s|__PAPER_STORAGE_TLS_CERTIFICATE__|$escaped_certificate|g" \
        -e "s|__PAPER_STORAGE_TLS_CERTIFICATE_KEY__|$escaped_certificate_key|g" \
        -e "s|__PAPER_STORAGE_PUBLIC_IP__|$escaped_public_ip|g" \
        "$nginx_template" > "$nginx_output"
}

render_bootstrap_nginx_config() {
    nginx_template=$1
    nginx_output=$2
    validate_public_ip "$PUBLIC_IP"
    escaped_public_ip=$(printf '%s' "$PUBLIC_IP" | sed 's/[&|]/\\&/g')
    sed -e "s|__PAPER_STORAGE_PUBLIC_IP__|$escaped_public_ip|g" \
        "$nginx_template" > "$nginx_output"
}

activate_nginx_config() {
    nginx_template=$1
    renderer=$2
    nginx_candidate=$(mktemp /etc/nginx/nginx.conf.sylg-candidate.XXXXXX)
    nginx_previous=$(mktemp /etc/nginx/nginx.conf.sylg-previous.XXXXXX)
    "$renderer" "$nginx_template" "$nginx_candidate"
    chown root:root "$nginx_candidate"
    chmod 0644 "$nginx_candidate"
    if ! nginx -t -c "$nginx_candidate"; then
        echo "新 Nginx 配置校验失败，保留当前配置" >&2
        return 1
    fi
    cp -p /etc/nginx/nginx.conf "$nginx_previous"
    mv -f "$nginx_candidate" /etc/nginx/nginx.conf
    nginx_candidate=
    if ! nginx -t; then
        cp -p "$nginx_previous" /etc/nginx/nginx.conf
        nginx -t || true
        echo "安装后的 Nginx 配置校验失败，已恢复上一版" >&2
        return 1
    fi
    nginx_activation_failed=0
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx || nginx_activation_failed=1
    else
        systemctl start nginx || nginx_activation_failed=1
    fi
    if [ "$nginx_activation_failed" -ne 0 ]; then
        cp -p "$nginx_previous" /etc/nginx/nginx.conf
        nginx -t || true
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx || true
        else
            systemctl start nginx || true
        fi
        echo "Nginx 启动或重载失败，已恢复上一版配置" >&2
        return 1
    fi
}

request_ip_certificate() {
    validate_certbot_version
    certbot_common_args="--non-interactive --agree-tos --no-eff-email"
    if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
        certbot_identity_args="--email $LETSENCRYPT_EMAIL"
    else
        certbot_identity_args="--register-unsafely-without-email"
        echo "未设置 LETSENCRYPT_EMAIL，ACME 账户不会接收续期告警。" >&2
    fi

    # 先用独立 lineage 验证短期 IP 证书流程，避免 staging 证书进入正式路径。
    # shellcheck disable=SC2086
    certbot certonly --staging --preferred-profile shortlived \
        --webroot --webroot-path /var/lib/letsencrypt \
        --ip-address "$PUBLIC_IP" --cert-name "$PUBLIC_IP-staging" \
        $certbot_common_args $certbot_identity_args
    # shellcheck disable=SC2086
    certbot certonly --preferred-profile shortlived --force-renewal \
        --webroot --webroot-path /var/lib/letsencrypt \
        --ip-address "$PUBLIC_IP" --cert-name "$PUBLIC_IP" \
        $certbot_common_args $certbot_identity_args
    validate_tls_certificate
    certbot delete --cert-name "$PUBLIC_IP-staging" --non-interactive || \
        echo "清理 staging 证书 lineage 失败，请人工执行 certbot delete。" >&2
}

install_certbot_deploy_hook() {
    hook_path=/etc/letsencrypt/renewal-hooks/deploy/paper-storage-nginx-reload.sh
    install -d -o root -g root -m 0755 "$(dirname "$hook_path")"
    printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'if nginx -t; then' \
        '    systemctl reload nginx' \
        'else' \
        '    logger -t paper-storage-acme "续期后 Nginx 配置校验失败，拒绝 reload"' \
        '    exit 1' \
        'fi' > "$hook_path"
    chown root:root "$hook_path"
    chmod 0755 "$hook_path"
}

validate_ssh_port() {
    ssh_port=$1
    case "$ssh_port" in
        ''|*[!0-9]*)
            echo "SSH_PORT 必须是 1 到 65535 的十进制整数" >&2
            return 1
            ;;
    esac
    if [ "${#ssh_port}" -gt 5 ] || [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
        echo "SSH_PORT 必须位于 1 到 65535" >&2
        return 1
    fi
}

audit_ufw_rules() {
    unexpected_rules=$(ufw show added | awk -v ssh_rule="${SSH_PORT}/tcp" '
        $1 == "ufw" && $2 == "allow" {
            if (NF != 3 || ($3 != ssh_rule && $3 != "80/tcp" && $3 != "443/tcp")) {
                print $0
            }
        }
    ')
    if [ -z "$unexpected_rules" ]; then
        return 0
    fi
    echo "检测到 SSH/HTTP/HTTPS 之外的 UFW ALLOW 规则：" >&2
    printf '%s\n' "$unexpected_rules" >&2
    if [ "${ALLOW_EXISTING_UFW_RULES:-0}" = "1" ]; then
        echo "已通过 ALLOW_EXISTING_UFW_RULES=1 明确保留这些规则。" >&2
        return 0
    fi
    echo "请人工核对规则；确认必须保留后再设置 ALLOW_EXISTING_UFW_RULES=1。" >&2
    return 1
}

swap_file_is_active() {
    active_swap_path=$1
    awk -v path="$active_swap_path" 'NR > 1 && $1 == path { found = 1 } END { exit !found }' "$SWAPS_FILE"
}

swap_signature_is_valid() {
    signature_path=$1
    swap_type=$(blkid -p -s TYPE -o value "$signature_path" 2>/dev/null || true)
    [ "$swap_type" = "swap" ] && file -b "$signature_path" | grep -qi 'swap file'
}

secure_swap_file() {
    secure_path=$1
    if [ "${PAPER_STORAGE_SKIP_OWNERSHIP:-0}" != "1" ]; then
        chown root:root "$secure_path"
    fi
    chmod 0600 "$secure_path"
}

deduplicate_fstab_swap() {
    fstab_swap_path=$1
    if [ -L "$FSTAB_PATH" ] || { [ -e "$FSTAB_PATH" ] && [ ! -f "$FSTAB_PATH" ]; }; then
        echo "fstab 不是普通文件，拒绝修改：$FSTAB_PATH" >&2
        return 1
    fi
    [ -e "$FSTAB_PATH" ] || : > "$FSTAB_PATH"
    fstab_new=$(mktemp "${FSTAB_PATH}.paper-storage.XXXXXX")
    awk -v path="$fstab_swap_path" '$1 != path { print } END { print path " none swap sw 0 0" }' "$FSTAB_PATH" > "$fstab_new"
    if [ "${PAPER_STORAGE_SKIP_OWNERSHIP:-0}" != "1" ]; then
        chown root:root "$fstab_new"
    fi
    chmod 0644 "$fstab_new"
    mv -f "$fstab_new" "$FSTAB_PATH"
    fstab_new=
}

prepare_swap_file() {
    swap_path=$1
    if [ -L "$swap_path" ]; then
        echo "Swap 路径不得是符号链接：$swap_path" >&2
        return 1
    fi
    if [ -e "$swap_path" ] && [ ! -f "$swap_path" ]; then
        echo "Swap 路径必须是普通文件：$swap_path" >&2
        return 1
    fi
    if [ -f "$swap_path" ]; then
        secure_swap_file "$swap_path"
    fi
    if swap_file_is_active "$swap_path"; then
        if ! swap_signature_is_valid "$swap_path"; then
            echo "活动 Swap 的签名校验失败，拒绝修改：$swap_path" >&2
            return 1
        fi
        deduplicate_fstab_swap "$swap_path"
        return 0
    fi

    if [ ! -f "$swap_path" ] || ! swap_signature_is_valid "$swap_path"; then
        swap_new=${swap_path}.new
        if [ -L "$swap_new" ] || { [ -e "$swap_new" ] && [ ! -f "$swap_new" ]; }; then
            echo "Swap 临时路径不安全：$swap_new" >&2
            return 1
        fi
        rm -f "$swap_new"
        fallocate -l "$SWAP_SIZE" "$swap_new"
        secure_swap_file "$swap_new"
        mkswap "$swap_new" >/dev/null
        sync "$swap_new"
        if ! swap_signature_is_valid "$swap_new"; then
            echo "新 Swap 文件签名校验失败" >&2
            return 1
        fi
        mv -f "$swap_new" "$swap_path"
        swap_new=
    fi
    secure_swap_file "$swap_path"
    deduplicate_fstab_swap "$swap_path"
    if [ "${PAPER_STORAGE_SKIP_SWAPON:-0}" != "1" ]; then
        swapon "$swap_path"
    fi
}

validate_elf_binary() {
    elf_path=$1
    if [ -L "$elf_path" ] || [ ! -f "$elf_path" ]; then
        echo "文件服务二进制必须是普通文件：$elf_path" >&2
        return 1
    fi
    elf_magic=$(od -An -tx1 -N4 "$elf_path" | tr -d ' \n')
    if [ "$elf_magic" != "7f454c46" ]; then
        echo "文件服务二进制不是 ELF 文件：$elf_path" >&2
        return 1
    fi
}

wait_for_health() {
    health_url=$1
    attempts=${PAPER_STORAGE_HEALTH_ATTEMPTS:-15}
    case "$attempts" in
        ''|*[!0-9]*)
            echo "PAPER_STORAGE_HEALTH_ATTEMPTS 必须是正整数" >&2
            return 1
            ;;
    esac
    if [ "$attempts" -lt 1 ]; then
        echo "PAPER_STORAGE_HEALTH_ATTEMPTS 必须是正整数" >&2
        return 1
    fi
    while [ "$attempts" -gt 0 ]; do
        if curl -fsS --max-time 2 "$health_url" >/dev/null; then
            return 0
        fi
        attempts=$((attempts - 1))
        if [ "$attempts" -gt 0 ]; then
            sleep 1
        fi
    done
    return 1
}

activate_binary_candidate() {
    binary_path=$1
    health_url=$2
    candidate_path=${binary_path}.new
    backup_path=${binary_path}.bak
    if [ -L "$candidate_path" ] || [ ! -f "$candidate_path" ]; then
        echo "待切换二进制不存在或不安全：$candidate_path" >&2
        return 1
    fi
    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
        echo "检测到未处理的二进制备份，请先核对：$backup_path" >&2
        return 1
    fi
    had_previous=0
    if [ -e "$binary_path" ] || [ -L "$binary_path" ]; then
        if [ -L "$binary_path" ] || [ ! -f "$binary_path" ]; then
            echo "现有二进制不是普通文件：$binary_path" >&2
            return 1
        fi
        cp -p "$binary_path" "$backup_path"
        sync "$backup_path"
        had_previous=1
    fi
    mv -f "$candidate_path" "$binary_path"
    binary_candidate=

    activation_failed=0
    if ! systemctl restart paper-storage; then
        activation_failed=1
    elif ! wait_for_health "$health_url"; then
        activation_failed=1
    fi
    if [ "$activation_failed" -eq 0 ]; then
        rm -f "$backup_path"
        return 0
    fi

    if [ "$had_previous" -eq 1 ]; then
        mv -f "$backup_path" "$binary_path"
        systemctl restart paper-storage || echo "旧版本恢复后重启失败，请立即人工处理" >&2
        echo "新版本启动或健康检查失败，已恢复旧二进制" >&2
    else
        rm -f "$binary_path"
        systemctl stop paper-storage || true
        echo "首次安装启动或健康检查失败，服务已停止" >&2
    fi
    return 1
}

if [ "${1:-}" = "--render-nginx" ]; then
    if [ "$#" -ne 3 ]; then
        echo "用法: install.sh --render-nginx 模板路径 输出路径" >&2
        exit 2
    fi
    render_nginx_config "$2" "$3"
    exit 0
fi

if [ "${1:-}" = "--render-bootstrap-nginx" ]; then
    if [ "$#" -ne 3 ]; then
        echo "用法: install.sh --render-bootstrap-nginx 模板路径 输出路径" >&2
        exit 2
    fi
    render_bootstrap_nginx_config "$2" "$3"
    exit 0
fi

if [ "${1:-}" = "--validate-tls-certificate" ]; then
    [ "$#" -eq 1 ] || exit 2
    validate_public_ip "$PUBLIC_IP"
    validate_tls_certificate
    exit $?
fi

if [ "${1:-}" = "--validate-ssh-port" ]; then
    [ "$#" -eq 2 ] || exit 2
    validate_ssh_port "$2"
    exit $?
fi

if [ "${1:-}" = "--validate-public-ip" ]; then
    [ "$#" -eq 2 ] || exit 2
    validate_public_ip "$2"
    exit $?
fi

if [ "${1:-}" = "--audit-ufw" ]; then
    validate_ssh_port "$SSH_PORT"
    audit_ufw_rules
    exit $?
fi

if [ "${1:-}" = "--prepare-swap" ]; then
    [ "$#" -eq 2 ] || exit 2
    prepare_swap_file "$2"
    exit $?
fi

if [ "${1:-}" = "--activate-binary" ]; then
    [ "$#" -eq 3 ] || exit 2
    activate_binary_candidate "$2" "$3"
    exit $?
fi

# Ubuntu 24.04 独立试卷文件服务器幂等安装脚本。
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行此脚本" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BINARY_SOURCE=${PAPER_STORAGE_BINARY:-"$SCRIPT_DIR/../../server/dist/paper-storage"}
binary_path=/opt/sylg-paper-storage/bin/paper-storage
binary_candidate=/opt/sylg-paper-storage/bin/paper-storage.new
binary_backup=/opt/sylg-paper-storage/bin/paper-storage.bak

validate_ssh_port "$SSH_PORT"
validate_public_ip "$PUBLIC_IP"
validate_acme_mode
if [ "$ACME_MODE" = "external" ] && \
   { [ -z "$TLS_CERT_PATH_WAS_SET" ] || \
     [ -z "$TLS_KEY_PATH_WAS_SET" ] || \
     [ -z "${PAPER_STORAGE_TLS_CERT_PATH:-}" ] || \
     [ -z "${PAPER_STORAGE_TLS_KEY_PATH:-}" ]; }; then
    echo "external 模式必须显式设置 PAPER_STORAGE_TLS_CERT_PATH 和 PAPER_STORAGE_TLS_KEY_PATH" >&2
    exit 1
fi
if ! validate_elf_binary "$BINARY_SOURCE"; then
    echo "未找到文件服务二进制：$BINARY_SOURCE" >&2
    echo "请先构建 Linux 二进制，或通过 PAPER_STORAGE_BINARY 指定路径" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends nginx ufw openssl ca-certificates curl file
if [ "$ACME_MODE" = "auto" ]; then
    apt-get install -y --no-install-recommends snapd
    ensure_modern_certbot
fi
if ! file -Lb "$BINARY_SOURCE" | grep -Eq '^ELF .* executable'; then
    echo "文件服务二进制不是可执行的 Linux ELF：$BINARY_SOURCE" >&2
    exit 1
fi
audit_ufw_rules

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
if [ -e "$binary_backup" ] || [ -L "$binary_backup" ]; then
    echo "检测到未处理的二进制备份，请先核对：$binary_backup" >&2
    exit 1
fi
if [ -L "$binary_candidate" ] || { [ -e "$binary_candidate" ] && [ ! -f "$binary_candidate" ]; }; then
    echo "二进制临时路径不安全：$binary_candidate" >&2
    exit 1
fi
rm -f "$binary_candidate"
install -o root -g paper-storage -m 0755 "$BINARY_SOURCE" "$binary_candidate"

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

# Nginx 工作进程与文件服务使用同一用户，避免放宽 PDF 的 0600 权限。
for directory in /var/lib/nginx /var/lib/nginx/body /var/lib/nginx/proxy /var/lib/nginx/fastcgi /var/lib/nginx/uwsgi /var/lib/nginx/scgi; do
    install -d -o paper-storage -g paper-storage -m 0700 "$directory"
done
install -d -o root -g paper-storage -m 0750 \
    /var/lib/letsencrypt \
    /var/lib/letsencrypt/.well-known \
    /var/lib/letsencrypt/.well-known/acme-challenge

# 已有 Swap 不足时新增专用文件；活动 Swap 不停用、不缩小、不重建。
swap_target_kib=2097152
swap_current_kib=$(awk 'NR > 1 { total += $3 } END { print total + 0 }' "$SWAPS_FILE")
managed_swap_path=
for candidate_swap_path in /swapfile-sylg-paper-storage /swapfile; do
    if [ -L "$candidate_swap_path" ]; then
        echo "Swap 路径不得是符号链接：$candidate_swap_path" >&2
        exit 1
    fi
    if [ -e "$candidate_swap_path" ] && [ ! -f "$candidate_swap_path" ]; then
        echo "Swap 路径必须是普通文件：$candidate_swap_path" >&2
        exit 1
    fi
    if swap_file_is_active "$candidate_swap_path" || awk -v path="$candidate_swap_path" '$1 == path { found = 1 } END { exit !found }' "$FSTAB_PATH"; then
        managed_swap_path=$candidate_swap_path
        break
    fi
done
if [ -n "$managed_swap_path" ]; then
    prepare_swap_file "$managed_swap_path"
elif [ "$swap_current_kib" -lt "$swap_target_kib" ]; then
    swap_path=/swapfile
    if [ -e "$swap_path" ] || grep -qs '^/swapfile[[:space:]]' "$SWAPS_FILE"; then
        swap_path=/swapfile-sylg-paper-storage
    fi
    prepare_swap_file "$swap_path"
fi

install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
if [ ! -f /etc/systemd/journald.conf.d/sylg-paper-storage.conf ] || \
   ! grep -qs '^MaxRetentionSec=14day$' /etc/systemd/journald.conf.d/sylg-paper-storage.conf; then
    printf '%s\n' '[Journal]' 'MaxRetentionSec=14day' > /etc/systemd/journald.conf.d/sylg-paper-storage.conf
    chmod 0644 /etc/systemd/journald.conf.d/sylg-paper-storage.conf
    systemctl restart systemd-journald
fi
journalctl --vacuum-time=14d >/dev/null

# 放行当前 SSH 端口后再设置默认策略，避免远程会话被锁死。
ufw allow "${SSH_PORT}/tcp"
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl daemon-reload
systemctl enable nginx paper-storage

if ! validate_tls_certificate; then
    if [ "$ACME_MODE" = "external" ]; then
        echo "外部管理的 TLS 证书未通过校验，拒绝替换 Nginx 配置。" >&2
        exit 1
    fi
    requested_validity_window=$TLS_MIN_VALIDITY_SECONDS
    TLS_MIN_VALIDITY_SECONDS=0
    if validate_tls_certificate; then
        # 旧证书仍可安全服务时保留完整 443，只在后台完成续期。
        activate_nginx_config "$SCRIPT_DIR/nginx.conf" render_nginx_config
    else
        activate_nginx_config "$SCRIPT_DIR/nginx-bootstrap.conf" render_bootstrap_nginx_config
    fi
    TLS_MIN_VALIDITY_SECONDS=$requested_validity_window
    request_ip_certificate
fi
validate_tls_certificate
activate_nginx_config "$SCRIPT_DIR/nginx.conf" render_nginx_config
if [ "$ACME_MODE" = "auto" ]; then
    install_certbot_deploy_hook
    systemctl enable --now certbot.timer
else
    echo "TLS 证书由外部系统管理，请确认已配置自动续期和 Nginx reload。" >&2
fi

if grep -qs 'CHANGE_ME_' /etc/sylg-paper-storage.env; then
    echo "请生成两把不同密钥并更新 /etc/sylg-paper-storage.env，然后重新运行脚本。"
else
    activate_binary_candidate "$binary_path" http://127.0.0.1:8081/healthz
fi
