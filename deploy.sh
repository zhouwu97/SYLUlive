#!/bin/bash
#
# 沈理校园后端部署脚本 (Ubuntu 无Docker版)
# 用法: chmod +x deploy.sh && ./deploy.sh
#

set -e

APP_NAME="shenliyuan"
APP_DIR="/opt/shenliyuan"
SERVICE_NAME="shenliyuan.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

echo "===== 沈理校园后端部署脚本 ====="
echo ""

# 检测是否使用sudo
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行此脚本或确保有root权限"
    exit 1
fi

# 1. 安装 Go (如果未安装)
if ! command -v go &> /dev/null; then
    echo "[1/5] 安装 Go 1.21+ ..."
    wget -q https://go.dev/dl/go1.21.6.linux-amd64.tar.gz -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo "Go 安装完成: $(go version)"
else
    echo "[1/5] Go 已安装: $(go version)"
fi

# 2. 创建应用目录
echo "[2/5] 创建应用目录..."
mkdir -p ${APP_DIR}
mkdir -p ${APP_DIR}/uploads

# 3. 复制文件
echo "[3/5] 复制应用文件..."
# 如果当前目录有go.mod，说明在源码目录执行
if [ -f "./server/go.mod" ]; then
    echo "  复制 server 目录..."
    cp -r ./server/* ${APP_DIR}/
elif [ -f "./go.mod" ]; then
    echo "  复制当前目录..."
    cp -r ./* ${APP_DIR}/
else
    echo "  请在项目根目录或包含server目录的位置执行此脚本"
    exit 1
fi

# 4. 设置环境变量文件
echo "[4/5] 配置环境变量..."
if [ ! -f "${APP_DIR}/.env" ]; then
    cat > ${APP_DIR}/.env << 'EOF'
# JWT 密钥（必填，生产环境请设置至少32位的随机字符串）
JWT_SECRET=change_me_to_random_string_at_least_32_chars

# 数据库路径
DSN=./shenliyuan.db

# 文件上传目录
UPLOAD_DIR=./uploads

# 超级管理员默认密码（必填）
SUPER_ADMIN_DEFAULT_PASSWORD=change_me_strong_password

# 运行模式
GIN_MODE=release
EOF
    echo "  已创建 .env 配置文件，请修改其中的密码！"
else
    echo "  .env 已存在，跳过创建"
fi

# 5. 下载依赖并编译
echo "[5/5] 编译应用..."
cd ${APP_DIR}
export PATH=$PATH:/usr/local/go/bin
go mod download
go build -o ${APP_NAME} ./cmd/main.go

# 6. 创建systemd服务
echo "创建 systemd 服务..."
cat > ${SERVICE_FILE} << EOF
[Unit]
Description=Shenliyuan Backend Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/${APP_NAME}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 7. 重载systemd并启动服务
echo "启动服务..."
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl restart ${SERVICE_NAME}

echo ""
echo "===== 部署完成 ====="
echo "服务状态: $(systemctl is-active ${SERVICE_NAME})"
echo ""
echo "常用命令:"
echo "  查看状态: systemctl status ${SERVICE_NAME}"
echo "  查看日志: journalctl -u ${SERVICE_NAME} -f"
echo "  重启服务: systemctl restart ${SERVICE_NAME}"
echo "  停止服务: systemctl stop ${SERVICE_NAME}"
echo ""
echo "请记得修改 ${APP_DIR}/.env 中的密码！"