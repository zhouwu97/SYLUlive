#!/bin/bash
#
# 沈理校园后端一键部署/更新脚本 (fwqtest - PostgreSQL)
# 用法: sudo bash deploy.sh
#

set -e

# ===================== 颜色 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERR]${NC}   $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }

# ===================== 配置 =====================
APP_NAME="shenliyuan"
APP_DIR="/opt/${APP_NAME}"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
BACKUP_DIR="${APP_DIR}/backups"
DB_NAME="shenliyuan"
DB_USER="shenliyuan"
DB_PASS=""
GO_VER="go1.23.4"

echo ""
echo "================================================"
echo "  沈理校园后端一键部署 (fwqtest)"
echo "================================================"
echo ""

# ===================== 权限检查 =====================
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 sudo 运行此脚本"; exit 1
fi

# ===================== 检查系统 =====================
check_system() {
    log_step "检查系统依赖..."
    apt-get update -qq 2>/dev/null

    for pkg in git wget gcc openssl curl; do
        if ! command -v $pkg &>/dev/null; then
            apt-get install -y -qq $pkg
        fi
    done
}

# ===================== 安装 Go =====================
setup_go() {
    if command -v go &>/dev/null; then
        local v=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
        if [ "$(printf '%s\n' "1.23" "$v" | sort -V | head -1)" = "1.23" ]; then
            log_info "Go 已安装: $(go version)"
            return
        fi
        log_warn "Go $v < 1.23，将升级"
    fi

    log_step "安装 Go 1.23..."
    local arch=$(uname -m)
    [ "$arch" = "x86_64" ] && go_arch="amd64" || go_arch="arm64"

    wget -q --show-progress "https://go.dev/dl/${GO_VER}.linux-${go_arch}.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    log_info "Go 安装完成: $(go version)"
}

# ===================== 安装配置 PostgreSQL =====================
setup_postgres() {
    log_step "配置 PostgreSQL..."

    # 生成随机密码
    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)
    fi

    # 安装 PostgreSQL
    if ! command -v psql &>/dev/null; then
        log_info "安装 PostgreSQL..."
        apt-get install -y -qq postgresql postgresql-client
    fi

    # 启动 PostgreSQL
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        systemctl start postgresql
        systemctl enable postgresql
    fi

    sleep 2

    # 创建数据库和用户
    local db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || true)
    if [ "$db_exists" != "1" ]; then
        log_info "创建数据库和用户..."
        sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true
        sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};" 2>/dev/null || true
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};" 2>/dev/null || true
        log_info "数据库已创建: ${DB_NAME}"
        log_info "  用户: ${DB_USER}"
        log_info "  密码: ${DB_PASS} (已写入 .env)"
    else
        log_info "数据库已存在，跳过创建"
        # 更新密码
        sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
    fi
}

# ===================== 拉取/更新代码 =====================
sync_code() {
    if [ -f "${APP_DIR}/server/go.mod" ]; then
        log_step "拉取最新代码..."
        git -C "${APP_DIR}" pull origin fwqtest
    else
        log_step "克隆项目..."
        rm -rf "$APP_DIR"
        git clone -b fwqtest https://github.com/zhouwu97/SYLUlive.git "$APP_DIR"
    fi
}

# ===================== 备份 =====================
backup_db() {
    local db_file="${APP_DIR}/shenliyuan.db"
    if [ -f "$db_file" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$db_file" "${BACKUP_DIR}/shenliyuan-$(date +%Y%m%d_%H%M%S).db"
        ls -t "${BACKUP_DIR}"/*.db 2>/dev/null | tail -n +6 | xargs -r rm -f
    fi
}

# ===================== 配置环境变量 =====================
setup_env() {
    log_step "配置环境变量..."

    local jwt_secret=""
    local admin_pass=""

    if [ -f "${APP_DIR}/.env" ]; then
        log_info ".env 已存在"
        source "${APP_DIR}/.env" 2>/dev/null || true
    fi

    # 检查是否仍为默认值
    if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" = "dev-secret-change-me" ] || [ "$JWT_SECRET" = "change_me_to_random_string_at_least_32_chars" ]; then
        jwt_secret=$(openssl rand -base64 32)
    fi
    if [ -z "$SUPER_ADMIN_DEFAULT_PASSWORD" ] || [ "$SUPER_ADMIN_DEFAULT_PASSWORD" = "dev-password-change-me" ] || [ "$SUPER_ADMIN_DEFAULT_PASSWORD" = "change_me_strong_password" ]; then
        admin_pass=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
    fi

    cat > "${APP_DIR}/.env" << EOF
# JWT 密钥
JWT_SECRET=${jwt_secret}

# PostgreSQL 连接串
DSN=host=127.0.0.1 port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME} sslmode=disable

# 文件上传目录
UPLOAD_DIR=./uploads

# 超级管理员默认密码
SUPER_ADMIN_DEFAULT_PASSWORD=${admin_pass}

# 运行模式
GIN_MODE=release
EOF

    log_info ".env 已配置"
    log_info "  超级管理员: super_admin / ${admin_pass}"
}

# ===================== 编译 =====================
build_app() {
    log_step "编译应用..."
    cd "${APP_DIR}/server"
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go

    go mod download
    go mod tidy

    CGO_ENABLED=0 go build \
        -ldflags="-s -w" \
        -o "${APP_DIR}/${APP_NAME}" \
        ./cmd/main.go

    chmod +x "${APP_DIR}/${APP_NAME}"
    log_info "编译完成: ${APP_DIR}/${APP_NAME}"
}

# ===================== 创建 systemd 服务 =====================
setup_service() {
    log_step "配置 systemd 服务..."

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Shenliyuan Backend Service
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/${APP_NAME}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# ===================== 启动服务 =====================
start_service() {
    log_step "启动服务..."

    if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
        systemctl stop "$APP_NAME"
        sleep 1
    fi

    systemctl enable "$APP_NAME"
    systemctl restart "$APP_NAME"
    sleep 3

    if systemctl is-active --quiet "$APP_NAME"; then
        log_info "服务运行中"
    else
        log_error "启动失败，日志: journalctl -u ${APP_NAME} -n 30"
        journalctl -u "$APP_NAME" -n 10 --no-pager
        exit 1
    fi
}

# ===================== 输出总结 =====================
print_summary() {
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="YOUR_SERVER_IP"

    echo ""
    echo "================================================"
    echo -e "  ${GREEN}一键部署完成!${NC}"
    echo "================================================"
    echo ""
    echo -e "  API 地址:        ${GREEN}http://${ip}:8080${NC}"
    echo -e "  服务状态:        ${GREEN}$(systemctl is-active ${APP_NAME})${NC}"
    echo ""
    echo "  常用命令:"
    echo "   查看状态:       systemctl status ${APP_NAME}"
    echo "   查看日志:       journalctl -u ${APP_NAME} -f"
    echo "   重启服务:       systemctl restart ${APP_NAME}"
    echo "   更新项目:       sudo bash ${APP_DIR}/deploy.sh"
    echo ""
    echo "  账号信息:"
    echo "   超级管理员:      super_admin"
    echo -e "   密码见:          ${APP_DIR}/.env"
    echo ""
    echo -e "  ${YELLOW}外网访问请开放 8080 端口:${NC}"
    echo "    ufw allow 8080"
    echo ""
}

# ===================== 主流程 =====================
check_system
setup_go
setup_postgres

# 如果已部署则停止旧服务
if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
    log_info "停止旧服务..."
    systemctl stop "$APP_NAME"
    backup_db
fi

sync_code

# 复制最新 deploy.sh 到部署目录（覆盖 repo 中的旧版本）
SCRIPT_PATH="$(readlink -f "$0")"
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "${APP_DIR}/deploy.sh" ]; then
    cp "$SCRIPT_PATH" "${APP_DIR}/deploy.sh"
    chmod +x "${APP_DIR}/deploy.sh"
fi

mkdir -p "${APP_DIR}/uploads"
setup_env
build_app
setup_service
start_service
print_summary
