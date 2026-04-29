# 部署说明 (无Docker)

## 服务器要求

- Ubuntu 20.04+ (或其他Linux发行版)
- Go 1.21+ (脚本会自动安装)

## 快速部署

```bash
# 1. 上传项目到服务器
scp -r ./shenliyuan root@156.233.229.232:/opt/

# 2. SSH登录服务器
ssh root@156.233.229.232

# 3. 进入目录并运行部署脚本
cd /opt/shenliyuan
chmod +x deploy.sh
./deploy.sh

# 4. 修改配置文件中的密码
nano /opt/shenliyuan/.env

# 5. 重启服务使配置生效
systemctl restart shenliyuan
```

## 服务管理

```bash
# 查看服务状态
systemctl status shenliyuan

# 查看实时日志
journalctl -u shenliyuan -f

# 重启服务
systemctl restart shenliyuan

# 停止服务
systemctl stop shenliyuan

# 卸载服务
systemctl disable shenliyuan
rm /etc/systemd/system/shenliyuan.service
systemctl daemon-reload
```

## 配置说明

编辑 `/opt/shenliyuan/.env`:

```env
# JWT密钥 (必填，至少32位)
JWT_SECRET=your_random_secret_here

# 超级管理员密码 (必填)
SUPER_ADMIN_DEFAULT_PASSWORD=your_strong_password

# 其他配置
DSN=./shenliyuan.db
UPLOAD_DIR=./uploads
GIN_MODE=release
```

## 默认账号

- 超级管理员: `super_admin` / (设置的超管密码)
- 管理员: `admin` / `admin123`
- 测试用户: `2024001` / `test123456`

## API地址

部署成功后: `http://156.233.229.232:8080`

## 防火墙

如果服务器有防火墙，需要开放8080端口:

```bash
ufw allow 8080
# 或者
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
```