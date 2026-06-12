# 部署与验收说明
`
本文档以当前服务端部署方式为准，适用于开发阶段和服务器手动运维。
`
## 基线原则
`
- `/opt/shenliyuan` 是唯一部署目录
- 线上行为只由 `/opt/shenliyuan` 当前代码、当前二进制和当前 systemd 进程决定
- 不要用 `/root/SYLUlive`、`/root/server`、`/root/client` 直接更新线上服务
- 排查顺序固定为：`commit -> 编译 -> 进程 -> token`
`
## 当前部署结构
`
服务配置以 systemd 为准：
`
- `WorkingDirectory=/opt/shenliyuan`
- `ExecStart=/opt/shenliyuan/shenliyuan`
`
常用检查命令：
`
```bash
systemctl cat shenliyuan
systemctl status shenliyuan --no-pager
readlink -f /proc/$(pgrep -o shenliyuan)/exe
```
`
## 首次部署
`
### 服务器要求
`
- Ubuntu 20.04+
- PostgreSQL
- Go 1.23+（`deploy.sh` 会自动处理）
`
### 部署步骤
`
```bash
git clone -b fwqtest https://github.com/zhouwu97/SYLUlive.git /opt/shenliyuan
cd /opt/shenliyuan
bash deploy.sh
```
`
部署完成后检查：
`
```bash
cd /opt/shenliyuan
git branch --show-current
git log -1 --oneline
systemctl status shenliyuan --no-pager
journalctl -u shenliyuan -n 50 --no-pager
```
`
## 日常更新
`
以后线上更新统一使用下面这套命令：
`
```bash
cd /opt/shenliyuan
git pull origin fwqtest
cd /opt/shenliyuan/server
go build -o /opt/shenliyuan/shenliyuan ./cmd/main.go
systemctl restart shenliyuan
```
`
更新后立即验证：
`
```bash
cd /opt/shenliyuan
git log -1 --oneline
systemctl is-active shenliyuan
journalctl -u shenliyuan -n 50 --no-pager
`
```
`
## 开发阶段重建
`
当前还在开发阶段、没有真实用户时，最干净的方式是直接重建部署目录和数据库：
`
```bash
systemctl stop shenliyuan
`
rm -rf /opt/shenliyuan
`
sudo -u postgres psql -c "DROP DATABASE IF EXISTS shenliyuan;"
sudo -u postgres psql -c "DROP USER IF EXISTS shenliyuan;"
`
git clone -b fwqtest https://github.com/zhouwu97/SYLUlive.git /opt/shenliyuan
`
cd /opt/shenliyuan
bash deploy.sh
```
`
这会绕开旧 schema 兼容问题，适合快速回到干净基线。
`
## 环境变量
`
生产环境实际使用 `/opt/shenliyuan/.env`。
`
常见字段：
`
```env
JWT_SECRET=your_random_secret
DSN=host=127.0.0.1 port=5432 user=shenliyuan password=your_password dbname=shenliyuan sslmode=disable
UPLOAD_DIR=./uploads
GIN_MODE=release
```
`
注意：
`
- `.env` 是运行配置，不是源码
- 删除部署目录前，如果你要保留历史配置，先备份 `.env`
- `uploads/` 是用户上传目录，正式环境删除前也应备份
`
## 超级管理员账号
`
当前系统超级管理员账号可在启动时通过环境变量配置，否则将使用默认账号。
`
环境变量配置（推荐）：
- `SUPER_ADMIN_ID` (默认: `admin`)
- `SUPER_ADMIN_PASSWORD` (默认: `admin123`)
`

注意：
`
- 当前超管账号不是以 `.env` 为准
- 如果服务端角色发生变化，必须重新登录一次，确保 JWT token 内的 `role` 同步更新
`
## 核心验收清单
`
### 基础验收
`
1. `/opt/shenliyuan` 当前 commit 正确
2. `shenliyuan` 服务为 `active`
3. `readlink -f /proc/$(pgrep -o shenliyuan)/exe` 指向 `/opt/shenliyuan/shenliyuan`
4. 超管账号可正常登录
5. “我”页显示“超级管理员”
`
### 邀请提权链路
`
目标链路：
`
- 超管邀请普通用户
- 用户同意后直接成为管理员
`
验证点：
`
1. 超管发起邀请
2. 普通用户能看到待处理邀请
3. 用户点击同意后返回“已同意邀请，你已成为管理员”
4. `GET /api/user/profile` 返回 `role: "admin"`
5. 新 token 中 `role` 也为 `admin`
6. `/api/admin/members` 返回 `super_admin + admin`
`
### 管理员罢免链路
`
目标链路：
`
- 管理员发起罢免
- 过半投票后目标降级为普通用户
`
验证点：
`
1. 管理员 A 发起罢免，返回剩余票数
2. `/api/admin/removals/pending` 出现待办
3. 另一管理员或超管投票
4. 过半后返回“管理员已被罢免”
5. `GET /api/user/profile` 返回目标账号 `role: "user"`
6. `/api/admin/members` 中该账号消失
7. `/api/admin/removals/pending` 清空
`
### 公告链路
`
验证点：
`
1. `GET /api/announcements` 返回 200
2. `GET /api/announcements/unread` 返回 200
3. 客户端公告弹窗和公告列表都能正常展示
`
## 故障排查
`
### 1. 代码明明更新了，线上表现还是旧版
`
按顺序检查：
`
```bash
cd /opt/shenliyuan
git log -1 --oneline
ls -l /opt/shenliyuan/shenliyuan
readlink -f /proc/$(pgrep -o shenliyuan)/exe
systemctl status shenliyuan --no-pager
```
`
### 2. 接口权限不对
`
优先看当前登录 token 是否还是旧角色。后端权限判断依赖 JWT claims 中的 `role`，不是每次都实时查数据库。
`
处理方法：
`
1. 退出登录
2. 重新登录
3. 再测接口
`
### 3. `AutoMigrate` 启动失败
`
开发阶段优先直接重建数据库和部署目录，不建议在脏 schema 上反复猜测迁移问题。
`
## 常用运维命令
`
```bash
# 查看服务状态
systemctl status shenliyuan
`
# 查
`
## 数据库引擎切换与迁移
`
代码层面已经原生支持了 PostgreSQL。在 server/cmd/main.go 中，系统会通过判断环境变量 DSN 是否包含 host= 或 port= 来自动决定使用哪个数据库驱动。
`
### 1. 修改配置文件切换数据库引擎
`
修改项目根目录下的 .env 文件，将 DSN 替换为 PostgreSQL 的连接字符串：
`
`env
# 原来的 SQLite 配置
# DSN=./shenliyuan.db
`
# 新的 PostgreSQL 配置 (请根据实际情况修改 host, user, password, dbname)
DSN=host=127.0.0.1 user=postgres password=你的密码 dbname=shenliyuan port=5432 sslmode=disable TimeZone=Asia/Shanghai
`
`
### 2. 迁移原有的 SQLite 数据
`
如果你已经在 SQLite 里产生了一些数据，在切换到 PostgreSQL 后，你可以使用以下方案将老数据搬迁过去：
`
#### 方案 A：使用自动化工具 pgloader (最推荐，速度极快)
pgloader 是一款专门用于向 PostgreSQL 导入数据的开源工具，原生支持直接从 SQLite 读取并转储到 PostgreSQL。
`
在 Linux/macOS 上安装后执行一条命令即可完成整库迁移：
`bash
pgloader ./shenliyuan.db postgresql://postgres:你的密码@localhost:5432/shenliyuan
`
*注意：使用 pgloader 前，建议先让 Go 服务连上 PostgreSQL 跑一次，让 GORM 自动建好表结构，然后再清空表导入，或者直接让 pgloader 建表。*
`
#### 方案 B：使用可视化数据库客户端 (如 DBeaver / Navicat)
1. 使用 **DBeaver** 同时连接你的 SQLite 文件和 PostgreSQL 数据库。
2. 选中 SQLite 里的所有表 -> 右键 -> **导出数据 (Export Data)**。
3. 目标端选择你刚建好的 PostgreSQL 数据库。
4. 勾选所有映射关系，点击下一步，它会自动帮你把数据 Copy 过去。
