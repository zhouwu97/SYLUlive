# 部署与验收说明
`
本文档以当前服务端部署方式为准，适用于开发阶段和服务器手动运维。
`
## 基线原则
`
- `/opt/shenliyuan-src` 是干净源码目录，只用于 `git pull`、依赖下载和编译
- `/opt/shenliyuan` 是线上运行目录，只存放 `.env`、运行二进制、上传文件、数据库文件和备份文件
- 线上行为由 `/opt/shenliyuan/shenliyuan` 二进制、`/opt/shenliyuan/.env` 配置和当前 systemd 进程决定
- 不要在 `/opt/shenliyuan` 执行 `git pull`，这个目录可能包含生产上传文件和历史备份
- 不要用 `/root/SYLUlive`、`/root/server`、`/root/client` 直接更新线上服务
- 排查顺序固定为：`commit -> 编译 -> 进程 -> token`
`
## 当前部署结构
`
服务配置以 systemd 为准：
`
- 源码目录：`/opt/shenliyuan-src`
- 运行目录：`/opt/shenliyuan`
- `WorkingDirectory=/opt/shenliyuan`
- `ExecStart=/opt/shenliyuan/shenliyuan`
`
常用检查命令：
`
```bash
systemctl cat shenliyuan
systemctl status shenliyuan --no-pager
cd /opt/shenliyuan-src && git status --short --branch
cd /opt/shenliyuan-src && git log -1 --oneline
readlink -f /proc/$(pgrep -o shenliyuan)/exe
```
`
## 首次部署
`
### 服务器要求
`
- Ubuntu 20.04+
- PostgreSQL
- Go 1.25+（`deploy.sh` 会自动处理）
`
### 部署步骤
`
```bash
mkdir -p /opt/shenliyuan
git clone -b fwqtest https://github.com/zhouwu97/SYLUlive.git /opt/shenliyuan-src

cd /opt/shenliyuan-src/server
go mod download
go build -o /opt/shenliyuan/shenliyuan ./cmd/main.go
chmod +x /opt/shenliyuan/shenliyuan

# 确认 /opt/shenliyuan/.env 已配置完成后启动服务
systemctl restart shenliyuan
```
`
部署完成后检查：
`
```bash
cd /opt/shenliyuan-src
git branch --show-current
git log -1 --oneline
git status --short --branch
systemctl status shenliyuan --no-pager
journalctl -u shenliyuan -n 50 --no-pager
```
`
## 日常更新
`
以后线上更新统一使用一键脚本：
`
```bash
deploy-shenliyuan
```
`
脚本等价于下面这套流程：
`
```bash
cd /opt/shenliyuan-src
git fetch origin
git checkout fwqtest
git pull --ff-only origin fwqtest

cd /opt/shenliyuan-src/server
go mod download
go build -o /opt/shenliyuan/shenliyuan.new ./cmd/main.go

cp -a /opt/shenliyuan/shenliyuan /opt/shenliyuan/shenliyuan.bak.$(date +%Y%m%d_%H%M%S)
mv /opt/shenliyuan/shenliyuan.new /opt/shenliyuan/shenliyuan
chmod +x /opt/shenliyuan/shenliyuan

systemctl restart shenliyuan
```
`
更新后立即验证：
`
```bash
cd /opt/shenliyuan-src
git log -1 --oneline
git status --short --branch

systemctl is-active shenliyuan
curl -s http://127.0.0.1:8080/api/version
journalctl -u shenliyuan -n 50 --no-pager
```

如果更新失败，先看服务状态和日志：
`
```bash
systemctl status shenliyuan --no-pager
journalctl -u shenliyuan -n 100 --no-pager
```
`
如需回滚到上一个二进制：
`
```bash
ls -lh /opt/shenliyuan/shenliyuan.bak.*
cp -a /opt/shenliyuan/shenliyuan.bak.具体时间 /opt/shenliyuan/shenliyuan
chmod +x /opt/shenliyuan/shenliyuan
systemctl restart shenliyuan
```

## 国内环境：Gitee 拉取并部署 Python 教务服务

Python 教务服务通常部署在国内服务器，GitHub 访问可能不稳定。国内服务器更新教务服务时，优先从 Gitee 拉取 `fwqtest` 分支，然后重启 `shenliyuan-edu.service`。

### 部署位置

- 源码目录：`/root/SYLUlive`
- Python 服务目录：`/root/SYLUlive/python-edu-service`
- systemd 服务：`shenliyuan-edu.service`
- 服务监听：`127.0.0.1:8000`
- 健康检查：`http://127.0.0.1:8000/health`

不要在 `/opt/shenliyuan` 执行 `git pull`。`/opt/shenliyuan` 是运行目录，可能包含线上二进制、配置、上传文件和历史备份。

### 从 Gitee 拉取源码

如果服务器已经配置好 `gitee` 远端，直接执行：

```bash
cd /root/SYLUlive
git fetch gitee fwqtest
git checkout fwqtest
git merge --ff-only FETCH_HEAD

git log -1 --oneline
git status --short --branch
```

如果服务器没有配置 `gitee` 远端，可以临时使用 Gitee HTTPS 地址拉取。不要把令牌写入文档、脚本或提交记录；建议通过环境变量传入：

```bash
export GITEE_USER="你的 Gitee 用户名"
export GITEE_TOKEN="你的 Gitee 令牌"

cd /root/SYLUlive
git fetch "https://${GITEE_USER}:${GITEE_TOKEN}@gitee.com/chunhezi/SYLUlive.git" fwqtest
git checkout fwqtest
git merge --ff-only FETCH_HEAD

unset GITEE_TOKEN
git log -1 --oneline
git status --short --branch
```

### 部署前检查

拉取完成后，先检查 Python 文件能否编译，并确认 FastAPI 入口能正常导入。这样可以提前发现 `schemas.py`、`routers/*.py` 这类启动期错误，避免服务进入反复重启。

```bash
cd /root/SYLUlive/python-edu-service

venv/bin/python -m py_compile \
  main.py \
  models/schemas.py \
  routers/courses.py \
  services/crawler.py

venv/bin/python -c "import sys; sys.path.insert(0, '.'); import main; print('main_import=ok')"
```

如果这里失败，不要重启服务。先修复语法错误、缺失 import 或损坏的字符串，再重新提交、推送、拉取。

### 重启教务服务

检查通过后重启 systemd 服务：

```bash
systemctl restart shenliyuan-edu
sleep 5
systemctl is-active shenliyuan-edu
systemctl status shenliyuan-edu --no-pager --lines=20
```

期望结果：

- `systemctl is-active shenliyuan-edu` 输出 `active`
- `systemctl status` 中显示 `Active: active (running)`
- 进程为 `uvicorn main:app --host 127.0.0.1 --port 8000`

### 健康检查

服务重启后必须做本地健康检查：

```bash
curl -fsS --max-time 8 http://127.0.0.1:8000/health
```

期望返回：

```json
{"status":"healthy"}
```

如果 `/health` 不存在或返回异常，再查看服务根路径和日志：

```bash
curl -v --max-time 8 http://127.0.0.1:8000/
journalctl -u shenliyuan-edu -n 100 --no-pager
```

### 常见故障

1. `SyntaxError: unterminated string literal`
   - 常见于 Python 文件开头 docstring 被写坏，例如 `\"\"\"` 被提交成普通文本。
   - 处理：修复对应文件后运行 `venv/bin/python -m py_compile ...`。

2. `NameError: name 'ManualCourseInput' is not defined`
   - 常见于路由函数使用了 schema，但 `from models.schemas import ...` 没导入。
   - 处理：补齐 import，再运行 `venv/bin/python -c "import sys; sys.path.insert(0, '.'); import main"`。

3. `shenliyuan-edu.service` 一直 `activating` 或反复重启
   - 先看日志，不要只看 `systemctl is-active`：

```bash
systemctl status shenliyuan-edu --no-pager --lines=40
journalctl -u shenliyuan-edu -n 100 --no-pager
```

4. `curl: (7) Failed to connect to 127.0.0.1 port 8000`
   - 通常表示 Uvicorn 没启动成功或启动后立即退出。
   - 处理：查看 `journalctl -u shenliyuan-edu -n 100 --no-pager`，优先修复最上面的 Python 异常。

### Go 主服务与教务服务的关系

Go 主服务通过环境变量中的 `EDU_SERVICE_URL` 调用 Python 教务服务。部署后如教务接口异常，需要同时检查：

```bash
# Go 主服务
systemctl status shenliyuan --no-pager
systemctl cat shenliyuan --no-pager

# Python 教务服务
systemctl status shenliyuan-edu --no-pager
curl -fsS --max-time 8 http://127.0.0.1:8000/health
```

如果 Go 主服务在另一台服务器上通过公网或内网访问教务服务，还要确认 `EDU_SERVICE_URL` 指向当前可访问的地址。

## 客户端 (APK) 更新

如果修改了 Flutter 客户端代码，需要重新打包 Android 安装包并上传到服务器，用户即可下载更新：

```bash
# 1. 在本地机器（需有 Flutter 环境）进行编译
cd client
flutter build apk --release

# 2. 将编译好的 APK 上传至服务器的 uploads 静态资源目录
# 本地生成的包路径：client/build/app/outputs/flutter-apk/app-release.apk
scp client/build/app/outputs/flutter-apk/app-release.apk root@<你的服务器IP>:/opt/shenliyuan/uploads/app-release.apk

# 3. 用户更新
# 上传完毕后，用户可以直接通过浏览器访问下载最新版：
# http://<你的服务器IP>/uploads/app-release.apk
```

## 开发阶段重建
`
当前还在开发阶段、没有真实用户时，最干净的方式是直接重建源码目录、运行目录和数据库：
`
```bash
systemctl stop shenliyuan
`
rm -rf /opt/shenliyuan-src
rm -rf /opt/shenliyuan
`
sudo -u postgres psql -c "DROP DATABASE IF EXISTS shenliyuan;"
sudo -u postgres psql -c "DROP USER IF EXISTS shenliyuan;"
`
mkdir -p /opt/shenliyuan
git clone -b fwqtest https://github.com/zhouwu97/SYLUlive.git /opt/shenliyuan-src
`
cd /opt/shenliyuan-src/server
go mod download
go build -o /opt/shenliyuan/shenliyuan ./cmd/main.go
chmod +x /opt/shenliyuan/shenliyuan
systemctl restart shenliyuan
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
EXAM_PAPER_DIR=/opt/shenliyuan/private/exam-papers
SUPER_ADMIN_ID=admin
SUPER_ADMIN_PASSWORD=your_random_admin_password
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
当前系统超级管理员账号必须在启动时通过环境变量配置，生产环境不再接受默认占位密码。
`
环境变量配置：
- `SUPER_ADMIN_ID`
- `SUPER_ADMIN_PASSWORD`
`

注意：
`
- 超级管理员账号与密码以 `/opt/shenliyuan/.env` 为准
- 如果服务端角色发生变化，必须重新登录一次，确保 JWT token 内的 `role` 同步更新
`
## 核心验收清单
`
### 基础验收
`
1. `/opt/shenliyuan-src` 当前 commit 正确
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
cd /opt/shenliyuan-src
git log -1 --oneline
git status --short --branch
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

### 竞赛计划官方条目去重迁移（20260710_01）

竞赛计划条件唯一索引不由 `AutoMigrate` 创建。部署包含该版本的后端前，必须先完成数据库备份，并在 `server` 目录按顺序执行：

```bash
# 1. 只读检查，输出重复组、保留 ID 和待软删除 ID
go run ./cmd/migrate_competition_calendar

# 2. 人工核对报告并确认备份后执行
go run ./cmd/migrate_competition_calendar --apply --backup-confirmed
```

迁移按 `is_custom_modified DESC, is_pinned DESC, updated_at DESC, id DESC` 保留记录，并创建只约束有效官方副本的条件唯一索引。迁移完成前，新后端会因只读约束校验失败而拒绝启动；不要通过删除校验绕过迁移。
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

## 试卷私有文件目录

试卷 PDF 必须保存在 `/opt/shenliyuan/private/exam-papers`，目录权限为 `0700`、文件权限为 `0600`。该目录不得配置到 Nginx 静态路由或 `/uploads`。部署前执行：

```bash
mkdir -p /opt/shenliyuan/private/exam-papers
chmod 0700 /opt/shenliyuan/private /opt/shenliyuan/private/exam-papers
```

## 独立试卷文件服务器

试卷文件服务使用域名 `sylulive.online`，根域名与 `www` 的 DNS 记录均指向 `139.196.148.174`。`www.sylulive.online` 只做 301 跳转，客户端上传、预览和下载统一使用根域名。不得记录服务器密码到仓库、部署日志或切换报告中；聊天中曾共享过的密码应在上线前轮换。

### 构建与首次安装

在可信构建机生成 Ubuntu 24.04 可执行文件：

```bash
cd server
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/paper-storage ./cmd/paper_storage
```

把仓库和二进制放到文件服务器后，以 root 执行：

```bash
cd deploy/paper-storage
PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
```

脚本创建非登录用户 `paper-storage`、`0700` 数据目录、`0600` 环境文件，安装 Nginx、UFW、certbot 和 systemd 单元，并在现有 Swap 小于 2 GiB 时新增 Swap。脚本不会停用或覆盖已有 Swap。安装脚本不会写入服务器 IP、密码或生产密钥。

生成两把不同的密钥，只写入 `/etc/sylg-paper-storage.env`：

```bash
openssl rand -hex 32
openssl rand -hex 32
```

第一把同时配置为主服务器的 `EXAM_PAPER_STORAGE_SIGNING_SECRET` 和文件服务器的 `PAPER_STORAGE_SIGNING_SECRET`；第二把同时配置为主服务器的 `EXAM_PAPER_STORAGE_RECEIPT_SECRET` 和文件服务器的 `PAPER_STORAGE_RECEIPT_SECRET`。两把密钥不得相同，也不得提交到 Git。

设置正式证书联系人并再次运行安装脚本，certbot 会替换 Nginx 临时证书：

```bash
LETSENCRYPT_EMAIL=管理员邮箱 PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
certbot renew --dry-run
curl -fsS https://sylulive.online/healthz
```

健康检查应返回 `status=ok`；磁盘使用率达到 70% 时返回 `warning`，达到 95% 时返回 `readonly`。上线前同时检查：

```bash
systemctl status paper-storage --no-pager
journalctl -u paper-storage -n 100 --no-pager
nginx -t
curl -fsS http://127.0.0.1:8081/healthz
curl -fsS https://sylulive.online/healthz
```

### 网络与 SSH 加固

UFW 仅放行 `22/tcp`、`80/tcp` 和 `443/tcp`。如果生产 SSH 端口不是 22，必须先额外放行实际端口并从第二个终端验证，再删除 22 规则。安装脚本不会直接关闭密码登录。

先配置普通运维账号和 SSH 公钥，确认 SSH 公钥登录成功后，再设置：

```text
PasswordAuthentication no
PermitRootLogin prohibit-password
```

修改后先执行 `sshd -t`，保持当前会话不退出，从第二个终端验证公钥登录成功后再关闭旧会话。

### Cloudflare、缓存与备份

在 Cloudflare 为 `/v1/files/*`、`/v1/uploads/*` 和 `/_paper_files/*` 建立 Cache Rule，操作选择绕过缓存；不要启用会缓存 PDF 响应的规则。源站和 Cloudflare 均应保留 `Cache-Control: private, no-store` 与 `Referrer-Policy: no-referrer`。

在云厂商控制台启用每日磁盘快照，至少保留 7 天。快照是灾难恢复手段，不替代每天核对数据库引用、文件数量、大小和 SHA-256。journald 日志保留 14 天；下载位置关闭访问日志，其他日志也不记录查询参数，避免短时 token 泄露。

### 更新、回滚与故障处理

更新前保留上一版二进制：

```bash
cp -a /opt/sylg-paper-storage/bin/paper-storage /opt/sylg-paper-storage/bin/paper-storage.bak
PAPER_STORAGE_BINARY=/实际路径/新版本-paper-storage ./deploy/paper-storage/install.sh
```

若新版本异常，先在主服务器把 `EXAM_PAPER_STORAGE_MODE` 切为 `readonly-remote`，停止新的远端上传。已标记为 `remote` 的试卷继续从文件服务器下载，本地记录继续走主服务器。文件服务二进制回滚命令：

```bash
install -o root -g paper-storage -m 0750 \
  /opt/sylg-paper-storage/bin/paper-storage.bak \
  /opt/sylg-paper-storage/bin/paper-storage
systemctl restart paper-storage
curl -fsS http://127.0.0.1:8081/healthz
```

不要在回滚时删除 `/opt/sylg-paper-storage/data`、远端业务记录或 `.trash`。如果 Nginx 配置导致启动失败，使用安装脚本首次保存的 `/etc/nginx/nginx.conf.pre-sylg-paper-storage` 恢复，执行 `nginx -t` 后再 reload。
