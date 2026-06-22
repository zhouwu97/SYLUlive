#!/bin/bash
#
# 沈理校园后端一键部署/更新脚本 (fwqtest - PostgreSQL)
# 用法: sudo bash deploy.sh
#

set -Eeuo pipefail

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
BACKUP_DIR="/var/backups/${APP_NAME}"
DB_NAME="shenliyuan"
DB_USER="shenliyuan"
DB_PASS=""
GO_VER="go1.23.4"

CURRENT_BINARY="${APP_DIR}/${APP_NAME}"
OLD_BINARY="${APP_DIR}/.${APP_NAME}.previous"
NEW_BINARY="${APP_DIR}/.${APP_NAME}.new"

# ===================== 部署状态 =====================
SERVICE_WAS_ACTIVE=0
SERVICE_WAS_STOPPED=0
DEPLOY_SUCCEEDED=0

echo ""
echo "================================================"
echo "  沈理校园后端一键部署 (fwqtest)"
echo "================================================"
echo ""

# ===================== 权限检查 =====================
if [ "$EUID" -ne 0 ]; then
  log_error "请使用 sudo 运行此脚本"
  exit 1
fi

# ===================== 异常恢复 =====================
restore_previous_binary() {
  if [ -s "$OLD_BINARY" ]; then
    log_warn "恢复上一版二进制..."
    cp -a "$OLD_BINARY" "$CURRENT_BINARY"
    chmod 0755 "$CURRENT_BINARY"
  fi
}

cleanup_on_exit() {
  local exit_code=$?

  if [ "$DEPLOY_SUCCEEDED" -ne 1 ] &&
     [ "$SERVICE_WAS_ACTIVE" -eq 1 ] &&
     [ "$SERVICE_WAS_STOPPED" -eq 1 ]; then
    restore_previous_binary
    log_warn "部署失败，尝试恢复原服务..."
    systemctl start "$APP_NAME" || log_error "旧服务恢复失败，需要立即人工处理"
  fi

  exit "$exit_code"
}

trap cleanup_on_exit EXIT

# ===================== 部署锁 =====================
acquire_deploy_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    log_error "缺少 flock，请先安装 util-linux"
    exit 1
  fi

  exec 9>"/run/lock/${APP_NAME}-deploy.lock"

  if ! flock -n 9; then
    log_error "已有另一个部署任务正在运行"
    exit 1
  fi
}

# ===================== 检查系统 =====================
check_system() {
  log_step "检查系统依赖..."
  apt-get update -qq 2>/dev/null

  for pkg in git wget gcc openssl curl sqlite3; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      apt-get install -y -qq "$pkg"
    fi
  done
}

# ===================== 安装 Go =====================
setup_go() {
  if command -v go >/dev/null 2>&1; then
    local v
    v=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
    if [ "$(printf '%s\n' "1.23" "$v" | sort -V | head -1)" = "1.23" ]; then
      log_info "Go 已安装: $(go version)"
      return
    fi
    log_warn "Go $v < 1.23，将升级"
  fi

  log_step "安装 Go 1.23..."
  local arch go_arch
  arch=$(uname -m)
  if [ "$arch" = "x86_64" ]; then
    go_arch="amd64"
  else
    go_arch="arm64"
  fi

  wget -q --show-progress \
    "https://go.dev/dl/${GO_VER}.linux-${go_arch}.tar.gz" \
    -O /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  export PATH=$PATH:/usr/local/go/bin
  log_info "Go 安装完成: $(go version)"
}

# ===================== 加载现有数据库密码 =====================
load_existing_db_password() {
  local env_file="${APP_DIR}/.env"

  if [ -f "$env_file" ]; then
    DB_PASS="$(
      sed -n 's/^DSN=.* password=\([^ ]*\).*$/\1/p' "$env_file" |
        tail -n 1
    )"
  fi
}

# ===================== 安装配置 PostgreSQL =====================
setup_postgres() {
  log_step "配置 PostgreSQL..."

  # 安装 PostgreSQL
  if ! command -v psql >/dev/null 2>&1; then
    log_info "安装 PostgreSQL..."
    apt-get install -y -qq postgresql postgresql-client
  fi

  # 启动 PostgreSQL
  if ! systemctl is-active --quiet postgresql 2>/dev/null; then
    systemctl start postgresql
    systemctl enable postgresql
  fi

  sleep 2

  # 检查角色和数据库是否存在
  local role_exists=0
  local db_exists=0

  if sudo -u postgres psql -tAc \
      "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null |
      grep -q '^1$'; then
    role_exists=1
  fi

  if sudo -u postgres psql -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null |
      grep -q '^1$'; then
    db_exists=1
  fi

  # 四种状态处理
  if [ "$db_exists" -eq 0 ] && [ "$role_exists" -eq 0 ]; then
    # 首次安装：创建角色和数据库
    log_info "首次安装，创建数据库和用户..."

    if [ -z "${DB_PASS:-}" ]; then
      DB_PASS="$(
        openssl rand -base64 24 |
          tr -dc 'a-zA-Z0-9' |
          head -c 24
      )"
    fi

    sudo -u postgres psql -v ON_ERROR_STOP=1 \
      -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
    sudo -u postgres psql -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
    sudo -u postgres psql -v ON_ERROR_STOP=1 \
      -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"

    log_info "数据库和用户已创建"

  elif [ "$db_exists" -eq 1 ] && [ "$role_exists" -eq 1 ]; then
    # 已部署环境：保留现有密码，不执行 ALTER USER
    if [ -z "${DB_PASS:-}" ]; then
      log_error "数据库已存在，但无法从 .env 中取得密码"
      exit 1
    fi
    log_info "数据库和用户已存在，保留现有配置"

  elif [ "$db_exists" -eq 1 ] && [ "$role_exists" -eq 0 ]; then
    log_error "数据库 ${DB_NAME} 存在但角色 ${DB_USER} 不存在，状态异常，拒绝部署"
    exit 1

  else
    log_error "角色 ${DB_USER} 存在但数据库 ${DB_NAME} 不存在，状态异常，拒绝部署"
    exit 1
  fi
}

# ===================== 备份 =====================
backup_postgres() {
  log_step "执行 PostgreSQL 数据库备份..."

  install -d -m 0700 "$BACKUP_DIR"

  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"

  if command -v pg_dump >/dev/null 2>&1; then
    local pg_db_exists=0
    if sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null |
        grep -q '^1$'; then
      pg_db_exists=1
    fi

    if [ "$pg_db_exists" -eq 1 ]; then
      local temp_file final_file
      final_file="${BACKUP_DIR}/${APP_NAME}-${timestamp}.dump"
      temp_file="$(mktemp "${BACKUP_DIR}/.${APP_NAME}-${timestamp}.XXXXXX")"

      log_info "备份 PostgreSQL 数据库..."

      # 重定向由当前 root shell 打开，postgres 不需要目录写权限
      if ! sudo -u postgres pg_dump \
          --format=custom \
          "$DB_NAME" >"$temp_file"; then
        rm -f "$temp_file"
        log_error "PostgreSQL 备份失败，拒绝继续部署"
        exit 1
      fi

      if [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        log_error "PostgreSQL 备份为空，拒绝继续部署"
        exit 1
      fi

      # 校验备份文件非空且 PostgreSQL Archive 目录可读取
      if ! pg_restore --list "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        log_error "PostgreSQL 备份 Archive 目录不可读取"
        exit 1
      fi

      mv "$temp_file" "$final_file"
      chmod 0600 "$final_file"

      # 保留最近 5 个 PostgreSQL 备份
      ls -t "${BACKUP_DIR}"/*.dump 2>/dev/null |
        tail -n +6 |
        xargs -r rm -f || true

      log_info "PostgreSQL 备份完成: $final_file"

      # 备份全局对象（角色等），失败仅警告
      local globals_file="${BACKUP_DIR}/postgres-globals-${timestamp}.sql"
      if sudo -u postgres pg_dumpall \
          --globals-only >"$globals_file" 2>/dev/null; then
        chmod 0600 "$globals_file"
        ls -t "${BACKUP_DIR}"/postgres-globals-*.sql 2>/dev/null |
          tail -n +6 |
          xargs -r rm -f || true
        log_info "PostgreSQL 全局对象备份完成"
      else
        rm -f "$globals_file"
        log_warn "PostgreSQL 全局对象备份失败（不影响部署）"
      fi
    fi
  fi
}

backup_legacy_sqlite() {
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"

  local db_file="${APP_DIR}/shenliyuan.db"
  if [ -f "$db_file" ]; then
    log_step "执行 SQLite 遗留数据库备份..."

    install -d -m 0700 "$BACKUP_DIR"

    local temp_sqlite="${BACKUP_DIR}/.shenliyuan-${timestamp}.db.tmp"
    local final_sqlite="${BACKUP_DIR}/shenliyuan-${timestamp}.db"

    log_info "备份 SQLite 遗留数据库..."

    if ! sqlite3 "$db_file" ".backup '${temp_sqlite}'"; then
      rm -f "$temp_sqlite"
      log_error "SQLite 备份失败，拒绝继续部署"
      exit 1
    fi

    local integrity
    integrity="$(sqlite3 "$temp_sqlite" 'PRAGMA integrity_check;')"
    if [ "$integrity" != "ok" ]; then
      rm -f "$temp_sqlite"
      log_error "SQLite 备份完整性检查失败"
      exit 1
    fi

    mv "$temp_sqlite" "$final_sqlite"
    chmod 0600 "$final_sqlite"

    # 保留最近 5 个 SQLite 备份
    ls -t "${BACKUP_DIR}"/*.db 2>/dev/null |
      tail -n +6 |
      xargs -r rm -f || true

    log_info "SQLite 备份完成: $final_sqlite"
  fi
}

# ===================== 拉取/更新代码 =====================
sync_code() {
  if [ ! -e "${APP_DIR}" ]; then
    log_step "首次克隆项目..."
    git clone -b fwqtest \
      https://github.com/zhouwu97/SYLUlive.git \
      "${APP_DIR}"
    return
  fi

  if [ ! -d "${APP_DIR}/.git" ] ||
     [ ! -f "${APP_DIR}/server/go.mod" ]; then
    log_error "${APP_DIR} 已存在但不是完整项目，拒绝自动删除"
    exit 1
  fi

  for protected in \
    uploads \
    shenliyuan.db \
    backups \
    .env \
    logs
  do
    if git -C "${APP_DIR}" ls-files -- "${protected}" |
        grep -q .; then
      log_error "生产数据被 Git 跟踪，拒绝部署: ${protected}"
      exit 1
    fi
  done

  log_step "拉取最新代码..."
  git -C "${APP_DIR}" fetch origin fwqtest
  git -C "${APP_DIR}" reset --hard origin/fwqtest

  git -C "${APP_DIR}" clean -fd \
    -e uploads/ \
    -e shenliyuan.db \
    -e backups/ \
    -e 'shenliyuan.bak.*' \
    -e .env \
    -e logs/
}

# ===================== 环境变量辅助函数 =====================
upsert_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

# ===================== 配置环境变量 =====================
setup_env() {
  log_step "配置环境变量..."

  local env_file="${APP_DIR}/.env"
  local jwt_secret=""
  local admin_pass=""

  # 从现有 .env 精确提取
  if [ -f "$env_file" ]; then
    jwt_secret="$(
      sed -n 's/^JWT_SECRET=//p' "$env_file" |
        tail -n 1
    )"

    admin_pass="$(
      sed -n 's/^SUPER_ADMIN_DEFAULT_PASSWORD=//p' "$env_file" |
        tail -n 1
    )"
  fi

  # 仅在值为空或默认占位符时生成新值
  if [ -z "${jwt_secret:-}" ] ||
     [ "$jwt_secret" = "dev-secret-change-me" ] ||
     [ "$jwt_secret" = "change_me_to_random_string_at_least_32_chars" ]; then
    jwt_secret="$(openssl rand -base64 32)"
  fi

  if [ -z "${admin_pass:-}" ] ||
     [ "$admin_pass" = "dev-password-change-me" ] ||
     [ "$admin_pass" = "change_me_strong_password" ]; then
    admin_pass="$(
      openssl rand -base64 18 |
        tr -dc 'a-zA-Z0-9' |
        head -c 20
    )"
  fi

  # 使用 upsert 保留未知配置项
  local temp_env="${env_file}.tmp"
  if [ -f "$env_file" ]; then
    cp "$env_file" "$temp_env"
  else
    : >"$temp_env"
  fi

  upsert_env_key "$temp_env" "JWT_SECRET" "$jwt_secret"
  upsert_env_key "$temp_env" "DSN" \
    "host=127.0.0.1 port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME} sslmode=disable"
  upsert_env_key "$temp_env" "UPLOAD_DIR" "./uploads"
  upsert_env_key "$temp_env" "SUPER_ADMIN_DEFAULT_PASSWORD" "$admin_pass"
  upsert_env_key "$temp_env" "GIN_MODE" "release"

  chmod 0600 "$temp_env"
  mv "$temp_env" "$env_file"

  log_info ".env 已配置"
}

# ===================== 编译 =====================
build_app() {
  log_step "编译应用..."

  rm -f -- "$NEW_BINARY"

  (
    cd "${APP_DIR}/server"
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go

    go mod download
    go mod tidy

    CGO_ENABLED=0 go build \
      -trimpath \
      -ldflags="-s -w" \
      -o "$NEW_BINARY" \
      ./cmd/main.go
  )

  if [ ! -s "$NEW_BINARY" ]; then
    log_error "新二进制无效"
    exit 1
  fi

  chmod 0755 "$NEW_BINARY"

  if [ -f "$CURRENT_BINARY" ]; then
    cp -a "$CURRENT_BINARY" "$OLD_BINARY"
  fi

  mv -f "$NEW_BINARY" "$CURRENT_BINARY"
  log_info "编译完成: $CURRENT_BINARY"
}

# ===================== 创建 systemd 服务 =====================
setup_service() {
  log_step "配置 systemd 服务..."

  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Shenliyuan Backend Service
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${CURRENT_BINARY}
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

  systemctl enable "$APP_NAME"
  systemctl restart "$APP_NAME"
  sleep 3

  if systemctl is-active --quiet "$APP_NAME"; then
    log_info "服务进程已启动"
  else
    log_error "启动失败，日志: journalctl -u ${APP_NAME} -n 30"
    journalctl -u "$APP_NAME" -n 10 --no-pager || true
    exit 1
  fi
}

# ===================== 健康检查 =====================
health_check() {
  log_step "执行服务健康检查..."

  local health_url="http://127.0.0.1:8080/health"
  local attempts=15

  for ((i = 1; i <= attempts; i++)); do
    if curl \
      --fail \
      --silent \
      --show-error \
      --max-time 3 \
      "$health_url" >/dev/null; then
      log_info "健康检查通过"
      return 0
    fi

    sleep 2
  done

  log_error "服务启动后健康检查失败"
  journalctl \
    -u "$APP_NAME" \
    -n 50 \
    --no-pager || true

  exit 1
}

# ===================== 输出总结 =====================
print_summary() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  [ -z "${ip:-}" ] && ip="YOUR_SERVER_IP"

  echo ""
  echo "================================================"
  echo -e "  ${GREEN}一键部署完成!${NC}"
  echo "================================================"
  echo ""
  echo -e "  API 地址:        ${GREEN}http://${ip}:8080${NC}"
  echo -e "  服务状态:        ${GREEN}$(systemctl is-active "${APP_NAME}")${NC}"
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
acquire_deploy_lock

check_system
setup_go

load_existing_db_password
setup_postgres

backup_postgres

if systemctl is-active --quiet "$APP_NAME" 2>/dev/null; then
  SERVICE_WAS_ACTIVE=1
  log_info "停止旧服务..."
  systemctl stop "$APP_NAME"
  SERVICE_WAS_STOPPED=1
fi

backup_legacy_sqlite
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
health_check

DEPLOY_SUCCEEDED=1

print_summary
