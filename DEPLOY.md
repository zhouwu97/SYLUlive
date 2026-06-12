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

#### 方案 C：迁移后的必做操作 (主键序列修复与数据校准)
无论使用何种工具迁移数据，**都必须在迁移完成后执行数据校准脚本**，否则会导致创建新帖子、新评论时报错 HTTP 500 (主键冲突)。

我们将这些修复命令打包成了一个便捷脚本：
1. 将本地的 `fix_postgres_data.sh` 上传到服务器。
2. 授予执行权限并运行（替换 `<数据库名>` 为你的实际数据库名，如 `shenliyuan`）：
```bash
chmod +x fix_postgres_data.sh
bash fix_postgres_data.sh <数据库名>
```

该脚本的具体作用：
1. **校准 `posts` 表的点赞数和评论数**：排除被软删除的回复。
2. **校准 `users` 表的获赞总数**：仅累加用户发出的帖子获得的点赞，排除回复的点赞。
3. **修复主键自增序列**：将 PostgreSQL 的 `id` 自增序列同步到迁移过来的最大 `id` 值，避免 `Unique Constraint Violation`。

---

## 故障记录与排查指南

### 2026-06-12 事故：登录显示"账号不存在"、帖子全部消失

#### 根本原因

`.env` 中的 `DSN` 配置错误。

```
# .env 里的错误配置
DSN=sqlite.db

# 正确配置应该是
DSN=/opt/shenliyuan/shenliyuan.db
```

服务器代码 `config.go` 中的逻辑是：
- 如果 DSN 为空 / `shenliyuan.db` / `./shenliyuan.db`，则自动指向 `/opt/shenliyuan/shenliyuan.db`
- **但 `sqlite.db` 不匹配上述任何条件**，所以服务器直接把 `sqlite.db` 当作数据库文件名

后果：服务器连接到了一个全新的空数据库 `sqlite.db`，而真正存有 73 个用户、65 条帖子的 `shenliyuan.db` 完全没被使用。

#### 同时修复的其他问题

| 问题 | 原因 | 修复方式 |
|------|------|----------|
| 首页一直转圈加载 | 服务器返回 `"posts": null`（Go nil slice），客户端 `as List` 强转崩溃 | 服务端 `post.go`：返回前 `if posts == nil { posts = []models.Post{} }`；客户端 `post_provider.dart`：改为 `as List? ?? []` |
| 反馈提交 401 未登录 | `/api/feedback` 使用了 `AuthMiddleware`（强制登录） | `main.go` 改为 `OptionalAuthMiddleware` |
| 编译报错 `undefined: time` | `main.go` 缺少 `"time"` 包导入 | import 区添加 `"time"` |

#### 排查思路（通用）

遇到"数据全没了"或"账号不存在"时，按以下顺序排查：

**第一步：确认数据库文件**
```bash
# 查看数据库文件是否存在、大小、最后修改时间
ls -lh /opt/shenliyuan/shenliyuan.db
ls -lh /opt/shenliyuan/sqlite.db    # 看看有没有意外的数据库文件
```

**第二步：确认 .env 中 DSN 指向**
```bash
grep -i "DSN" /opt/shenliyuan/.env
```
确保 DSN 指向的是有数据的那个 `.db` 文件。

**第三步：直接查数据库验证数据是否存在**
```bash
sqlite3 /opt/shenliyuan/shenliyuan.db "SELECT COUNT(*) FROM users;"
sqlite3 /opt/shenliyuan/shenliyuan.db "SELECT COUNT(*) FROM posts;"
# 查找具体账号
sqlite3 /opt/shenliyuan/shenliyuan.db "SELECT id, student_id, nickname FROM users WHERE student_id = '你的学号';"
```

**第四步：看服务日志确认实际报错**
```bash
journalctl -u shenliyuan -n 50 --no-pager
```
关注以下关键信息：
- `使用 SQLite 数据库` / `使用 PostgreSQL 数据库` — 确认连接的数据库类型
- `record not found` — 说明查到了数据库但没找到记录
- 具体的 SQL 语句 — 确认查的是哪张表、条件是什么

**第五步：确认服务正常运行**
```bash
systemctl is-active shenliyuan
ss -tlnp | grep 8080
```

#### 一键诊断脚本

以后遇到类似问题，直接在服务器上跑这段：

```bash
echo "=== DSN配置 ===" && grep DSN /opt/shenliyuan/.env
echo "=== 数据库文件 ===" && ls -lh /opt/shenliyuan/*.db 2>/dev/null
echo "=== 用户数 ===" && sqlite3 /opt/shenliyuan/shenliyuan.db "SELECT COUNT(*) FROM users;" 2>/dev/null
echo "=== 帖子数 ===" && sqlite3 /opt/shenliyuan/shenliyuan.db "SELECT COUNT(*) FROM posts;" 2>/dev/null
echo "=== 服务状态 ===" && systemctl is-active shenliyuan
echo "=== 最近错误 ===" && journalctl -u shenliyuan -n 10 --no-pager -p err
```
