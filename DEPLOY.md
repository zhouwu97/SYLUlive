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

## 官网目录隔离

官网静态文件与 Flutter Web 构建产物必须分开管理：

- 生产 Nginx 官网根目录为 `/opt/sylulive-site-v5`，该目录默认设置为不可写保护
- `/opt/shenliyuan/web` 不是官网发布入口，禁止把 `client/build/web` 复制到该目录或官网根目录
- 官网更新只能使用服务器上的 `/usr/local/sbin/update-sylulive-site-v5`，脚本会检查首页标题、必需资源，并拒绝 Flutter Web 特征文件
- 官网 HTTPS server 必须包含仓库中的 `nginx/sylulive-site-v5-deep-links.conf` 路由片段，确保 Android App Links 与 `/team/{id}` 落地页不被首页回退规则吞掉
- Android 模拟器调试、`flutter run` 和 `flutter build apk` 不需要也不允许触碰官网目录

发布官网时，将完整的 `sylulive_site_v5` 目录传到服务器临时目录后执行：

```bash
sudo /usr/local/sbin/update-sylulive-site-v5 /tmp/sylulive_site_v5
```

脚本会先保留上一版官网、校验 Nginx 配置，再 reload；发布失败会恢复上一版。后端 `deploy-shenliyuan` 只更新后端二进制，不得扩展为网页目录同步。

官网 v5 的深链基础设施随静态发布包管理：

- `/.well-known/assetlinks.json` 返回 `sylulive_site_v5/.well-known/assetlinks.json`
- `/team/{id}` 使用 `try_files /team/index.html =404`，不做 302/301 到 `/team/index.html`
- `deploy/update-sylulive-site-v5` 会拒绝缺少上述两个资源的发布包，也会拒绝未安装深链 Nginx 路由的生产环境

Android release 发布前必须执行 `apksigner verify --print-certs app-release.apk`，并确认 SHA-256
包含在 `assetlinks.json` 中。当前 release 指纹为
`A3:67:48:6B:8B:5D:5E:EB:F6:7D:28:49:80:9C:B9:B0:9C:5C:3E:4D:C9:0D:80:15:13:4A:F4:16:07:7E:FB:9E`；发布脚本也会对该指纹执行门禁检查。
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

## 图片公开上传的授权静态传输（Docker P3）

Docker 部署中的 `/uploads/` 仍然先反代到 Go 的 `ServePublic`。图片变体 worker 与
X-Accel 静态直传由 `.env` 显式配置，生产目标值均为 `true`：Go 启动时会自动为历史公开
图片执行补偿任务（补建变体任务），worker 仅在 `IMAGE_VARIANT_WORKER_ENABLED=true`
时启动并消化 pending 任务；变体就绪前客户端继续回退原图，不会出现长期 404。只有 Go
根据 `files.access_scope = public` 完成授权、通过 `ResolveUploadPath` 路径校验并确认
文件存在后，才会返回 `X-Accel-Redirect`。Nginx 的目标位置是 `internal`，客户端不能
直接请求它。`GIN_MODE=release` 时两个开关缺失或为空会直接拒绝启动，避免漏配静默回退。

生产 `.env` 目标值（compose 对两者使用 `:?` 强制显式提供）：

```env
UPLOAD_DIR=/app/uploads
IMAGE_VARIANT_WORKER_ENABLED=true
UPLOAD_USE_ACCEL_REDIRECT=true
UPLOAD_ACCEL_PREFIX=/_internal/uploads/
```

回退开关（worker 异常或传输链路异常时使用；改为 false 后仍必须显式保留在 `.env` 中）：

```env
IMAGE_VARIANT_WORKER_ENABLED=false
UPLOAD_USE_ACCEL_REDIRECT=false
```

`docker-compose.yml` 中 `server_data` 同时挂载到 Go 的 `/app/uploads` 和 Nginx 的
`/var/lib/sylulive/uploads`，Nginx 挂载必须带 `:ro`。不要把 `exam_paper_data`、
`competition_award_evidence_data` 或任何私有目录挂载到 Nginx；如果修改 `UPLOAD_DIR`，
必须同步重新验证 Go 的存储路径和 Nginx alias，未完成前先把 `UPLOAD_USE_ACCEL_REDIRECT`
改回 `false` 并重启 Go。

### 部署时检查

按以下顺序执行，任一步失败都不要发布新默认值：

1. 确认 P2 worker 和 API 的原图回退逻辑已发布，pending、failed、unsupported 不会让客户端请求长期 404。
2. 历史公开图片缺宽高时（`image_pipeline_stats.sql` 的 `public_missing_dimensions` 不为 0），
   先跑 `server/cmd/backfill_image_metadata --dry-run` 预览、去掉参数实跑，再重启 Go，
   让启动期 `BackfillPublicImageVariantTasks` 按补齐后的宽高为长边 >1280 的图片补建 viewer 任务。
3. 运行 `bash scripts/image_pipeline_verify.sh` 硬门禁：`PUBLIC_URL` 与 `PRIVATE_URL` 必填；
   thumb/medium/viewer 轮询超时、数据库统计失败、pending 未下降、failed 超阈值、
   `public_without_any_variant > 0` 任一命中都会以非零退出，未通过不得发布。
4. 确认 Go 与 Nginx 使用同一公开上传共享卷，且 Nginx 对该卷只读挂载；目录中的路径只能由服务端生成。
5. 渲染 Compose 配置并检查挂载：

```bash
docker compose config
docker compose config | grep -E 'server_data:/app/uploads|server_data:/var/lib/sylulive/uploads:ro'
```

6. 校验 Nginx 配置：

```bash
docker compose run --rm --no-deps nginx nginx -t
```

7. 用测试图片验证：公开图片必须在 Go 允许后正常返回；私有图片、包含 `..` 的路径和
   `/_internal/uploads/` 的外部请求都必须被拒绝。Go 拒绝时 Nginx 不得回退为静态文件。

检查通过后重新创建 Go 和 Nginx 容器，并再次执行 `nginx -t`。开关只改变已通过 Go 授权的
公开文件传输方式，不改变数据库权限判断，也不能让客户端访问 internal 位置。

### 缓存、发布与回退

- 可撤回的公开上传文件路径由内容哈希构成，Go 返回有界 TTL 的公开 `Cache-Control`
  （`public, max-age=86400, stale-while-revalidate=604800`）：内容不可变不代表访问权限
  不可变（`access_scope` 动态判断），因此不下发一年期 immutable；浏览器命中不超过 24 小时，
  被撤回文件不存在长期缓存问题。Nginx 不覆盖该响应头，也不为 404 或鉴权失败设置共享长缓存。
  未来引入共享缓存层前，必须先把公开资源与私有（JWT）资源拆分为不同的 URL 空间，
  否则 `/uploads/` 不得配置 `proxy_cache` 或 CDN。
- 私有文件始终保持 `private, no-store`，不得经 Nginx 外部静态路径或 CDN 访问。
- 发布顺序固定为 P2 worker 和 API 回退、客户端资源选择、最后发布 P3。客户端预取没有远程
  开关，不能把服务端开关描述成客户端预取的关闭开关。
- 回退时先停 worker，把 `UPLOAD_USE_ACCEL_REDIRECT` 改回 `false` 并重启 Go；继续返回 origin URL，保留原图和已经生成的变体。不得删除文件、批量 purge 缓存或改变私有文件权限。
- 若变体 worker 出现异常，先将 `IMAGE_VARIANT_WORKER_ENABLED` 改回 `false` 并重启 Go；保留原图和已生成变体，不删除任务记录或文件。

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
git clone -b main https://github.com/zhouwu97/SYLUlive.git /opt/shenliyuan-src

cd /opt/shenliyuan-src/server
go mod download
go build -o /opt/shenliyuan/shenliyuan ./cmd
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
git checkout main
git pull --ff-only origin main

cd /opt/shenliyuan-src/server
go mod download
go build -o /opt/shenliyuan/shenliyuan.new ./cmd

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

Python 教务服务通常部署在国内服务器，GitHub 访问可能不稳定。国内服务器更新教务服务时，优先从 Gitee 拉取 `main` 分支，然后重启 `shenliyuan-edu.service`。

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
git fetch gitee main
git checkout main
git merge --ff-only FETCH_HEAD

git log -1 --oneline
git status --short --branch
```

如果服务器没有配置 `gitee` 远端，可以临时使用 Gitee HTTPS 地址拉取。不要把令牌写入文档、脚本或提交记录；建议通过环境变量传入：

```bash
export GITEE_USER="你的 Gitee 用户名"
export GITEE_TOKEN="你的 Gitee 令牌"

cd /root/SYLUlive
git fetch "https://${GITEE_USER}:${GITEE_TOKEN}@gitee.com/chunhezi/SYLUlive.git" main
git checkout main
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

## 客户端 (APK) 发布与强制更新

不要再把 APK 复制到公开的 `/uploads/app-release.apk`。正式安装包由服务端的
应用版本记录管理，只有超级管理员显式发布后的版本才能被客户端下载。

```bash
# 1. 在本地机器（需有 Flutter 环境）产出已签名的 release APK
cd client
flutter build apk --release

# 2. 部署服务端代码并确认运行目录可写；不要把 APK 放入 /uploads
mkdir -p /opt/shenliyuan/releases/android/stable/.tmp
chown -R <运行服务用户>:<运行服务组> /opt/shenliyuan/releases
chmod -R 750 /opt/shenliyuan/releases
```

随后使用新版客户端的“超级管理员面板 -> 应用版本”：选择 APK，填写
`version_name`、递增的 `version_code`、更新说明和
`minimum_supported_version_code`，先创建草稿并核对 SHA-256，再执行“发布”。

上线顺序必须分两阶段：

1. 先发布携带版本请求头与应用内更新能力的桥接版本，保持：

   ```env
   APP_UPDATE_ENFORCEMENT_ENABLED=true
   APP_UPDATE_ALLOW_MISSING_VERSION_HEADERS=true
   ```

2. 覆盖率足够后，将 `APP_UPDATE_ALLOW_MISSING_VERSION_HEADERS=false`。此时未
   上报版本头或低于当前 `minimum_supported_version_code` 的业务请求会返回
   `426 APP_UPDATE_REQUIRED`；`/api/app/update` 与 APK 下载接口仍然可访问。

验证版本策略时，可用实际发布版本号替换下列参数：

```bash
curl -sS 'http://127.0.0.1:8080/api/app/update?platform=android&channel=stable&version_name=1.6.2&version_code=1602'
curl -I 'http://127.0.0.1:8080/api/app/releases/<release_id>/download'
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
git clone -b main https://github.com/zhouwu97/SYLUlive.git /opt/shenliyuan-src
`
cd /opt/shenliyuan-src/server
go mod download
go build -o /opt/shenliyuan/shenliyuan ./cmd
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
COMPETITION_AWARD_EVIDENCE_DIR=/opt/shenliyuan/private/competition-award-evidence
SUPER_ADMIN_ID=admin
SUPER_ADMIN_PASSWORD=your_random_admin_password
GIN_MODE=release

# 应用内更新：APK 发布与下载
APP_RELEASE_DIR=/opt/shenliyuan/releases
APP_RELEASE_MAX_SIZE_MB=200
APP_UPDATE_ENFORCEMENT_ENABLED=false
APP_UPDATE_ALLOW_MISSING_VERSION_HEADERS=true
APP_RELEASE_USE_ACCEL_REDIRECT=false
APP_RELEASE_ACCEL_PREFIX=/_internal/app-releases/
```

应用内更新目录权限：

```bash
mkdir -p /opt/shenliyuan/releases/android/stable/.tmp
chown -R <运行服务用户>:<运行服务组> /opt/shenliyuan/releases
chmod -R 750 /opt/shenliyuan/releases
```

`APP_RELEASE_USE_ACCEL_REDIRECT` 默认 `false`，此时 Go 直接通过
`http.ServeContent` 输出 APK。等 Nginx 配置好下面的内部 location 后再改成
`true`。Nginx 示例：

```nginx
location /_internal/app-releases/ {
    internal;
    alias /opt/shenliyuan/releases/;
    sendfile on;
    aio threads;
}
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

试卷文件服务直接使用公网 IP `139.196.148.174`，不配置或复用 `sylulive.online` 业务域名。生产 TLS 证书的 SAN 必须包含 `IP Address:139.196.148.174`，客户端上传、预览和下载均直连该 IP。不得记录服务器密码到仓库、部署日志或切换报告中；聊天中曾共享过的密码应在上线前轮换。

### 构建与首次安装

在可信构建机生成 Ubuntu 24.04 可执行文件：

```bash
cd server
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/paper-storage ./cmd/paper_storage
```

把仓库和二进制放到文件服务器后，以 root 执行安装。`auto` 模式要求 Certbot 5.4 或更高版本；脚本会在需要时通过 Snap 安装新版 Certbot，先加载仅开放 80 端口 challenge 的 bootstrap 配置，完成 staging 验证和正式 IP 证书签发后才开放 443：

```bash
cd deploy/paper-storage
PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
```

脚本创建非登录用户 `paper-storage`、`0700` 数据目录、`0600` 环境文件，安装 Nginx、UFW、Certbot 和 systemd 单元，并在现有 Swap 小于 2 GiB 时新增 Swap。活动 Swap 不会被停用或重建；非活动文件会同时通过 `blkid` 与 `file` 校验签名，损坏文件使用 `.new` 完整创建并同步后原子替换。符号链接和非普通文件会被拒绝。生产证书不存在、私钥不匹配、有效期不足、SAN 错误或证书链不受系统信任时，脚本会拒绝渲染正式 Nginx 配置，不会回退 snakeoil 或自签证书。

生成两把不同的密钥，只写入 `/etc/sylg-paper-storage.env`：

```bash
openssl rand -hex 32
openssl rand -hex 32
```

第一把同时配置为主服务器的 `EXAM_PAPER_STORAGE_SIGNING_SECRET` 和文件服务器的 `PAPER_STORAGE_SIGNING_SECRET`；第二把同时配置为主服务器的 `EXAM_PAPER_STORAGE_RECEIPT_SECRET` 和文件服务器的 `PAPER_STORAGE_RECEIPT_SECRET`。两把密钥不得相同，也不得提交到 Git。

156 主服务器切换远端存储时使用以下配置；两个密钥值分别与 139 对应配置一致，但彼此必须不同：

```env
EXAM_PAPER_STORAGE_MODE=remote
EXAM_PAPER_STORAGE_BASE_URL=https://139.196.148.174
EXAM_PAPER_STORAGE_SIGNING_SECRET=<高强度随机密钥A>
EXAM_PAPER_STORAGE_RECEIPT_SECRET=<高强度随机密钥B>
```

写入真实密钥、确认公网 80/443 已放行后，首次签发正式证书时提供联系人邮箱；Certbot 会申请受系统信任的短期 IP 证书并启用自动续期 timer，deploy hook 只会在 `nginx -t` 成功后 reload：

```bash
LETSENCRYPT_EMAIL=管理员邮箱 PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
certbot renew --dry-run
openssl s_client -connect 139.196.148.174:443 -servername 139.196.148.174 -showcerts
curl -fsS https://139.196.148.174/healthz
```

证书由外部系统管理时，必须同时显式指定证书和私钥；脚本仍会执行全部证书校验：

```bash
PAPER_STORAGE_ACME_MODE=external \
PAPER_STORAGE_TLS_CERT_PATH=/受控路径/fullchain.pem \
PAPER_STORAGE_TLS_KEY_PATH=/受控路径/privkey.pem \
PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
```

### 历史试卷文件迁移

迁移命令只处理仍有效的 `pending`、`published` 本地试卷记录。它会流式读取主服务器上的原文件，重新计算实际大小和 SHA-256，再通过带 `metadata` scope 的短时授权读取文件服务器元数据；数据库记录、本地文件和远端文件的 key、大小、SHA-256 全部一致时，才允许把 `storage_backend` 条件更新为 `remote`。命令不会重新解析或解密 PDF，不会删除源文件，也不会输出密钥或授权 token。

先在文件服务器准备目标目录，再从主服务器复制。SSH 用户、端口和密钥路径按生产实际值填写，不要把密码写入脚本或命令历史：

```bash
# 文件服务器：目标目录必须归 paper-storage 用户管理
install -d -o paper-storage -g paper-storage -m 0700 \
  /opt/sylg-paper-storage/data/exam-papers

# 主服务器：保持 file_key 原文件名，不复制内部状态和临时文件
rsync -a --checksum --itemize-changes \
  --exclude='/.trash/' --exclude='/.pending/' --exclude='/.sessions/' --exclude='/.upload-*' \
  -e "ssh -p <SSH端口> -i <SSH私钥路径>" \
  /opt/shenliyuan/private/exam-papers/ \
  <文件服务器SSH用户>@139.196.148.174:/opt/sylg-paper-storage/data/exam-papers/

# 文件服务器：复制完成后恢复服务属主和私有权限
chown -R paper-storage:paper-storage /opt/sylg-paper-storage/data/exam-papers
find /opt/sylg-paper-storage/data/exam-papers -type d -exec chmod 0700 {} +
find /opt/sylg-paper-storage/data/exam-papers -type f -exec chmod 0600 {} +
```

`--checksum` 会按内容核对源和目标。不得复制 `.trash`、`.pending`、`.sessions` 或迁移期间产生的临时文件；目标端权限修复命令必须在文件服务器本机执行。

复制后先运行默认 dry-run。命令从主服务器 `.env` 读取 `DSN`、`EXAM_PAPER_DIR`、`EXAM_PAPER_STORAGE_BASE_URL` 和签名密钥；生产环境应已配置文件服务地址 `https://139.196.148.174`。可用 `--id` 单独演练，也可用 `--page-size` 调整批量分页：

```bash
cd /opt/shenliyuan-src/server

# 默认即 dry-run；显式写出便于操作审计
go run ./cmd/migrate_exam_papers_remote --dry-run
go run ./cmd/migrate_exam_papers_remote --dry-run --id <试卷ID>
```

确认报告中 `failed=0`，并人工核对待迁移数量、源文件、目标文件两份副本后，再显式执行正式更新：

```bash
go run ./cmd/migrate_exam_papers_remote --apply
# 或逐条切换
go run ./cmd/migrate_exam_papers_remote --apply --id <试卷ID>
```

任意单条文件缺失、符号链接、路径非法、远端 metadata 缺失或不一致都会保留该记录为 `local`；批量任务会继续检查其余记录，最终以非零状态退出并汇总 `failed`。并发修改过的记录也不会被误标为远端。修正文件后可安全重跑；已是 `remote` 的记录会被跳过。

迁移完成后主服务器源文件以只读方式保留至少 7 天，在备份和线上下载核验稳定前不得删除。发生异常时，把主服务器 `EXAM_PAPER_STORAGE_MODE` 设为 `readonly-remote` 并重启，可停止新远端上传；已标记为 `remote` 的记录仍从文件服务器读取，未迁移的 `local` 记录仍使用主服务器副本。该开关不会自动把数据库标记改回 `local`，因此不要依赖它将已迁移记录切回旧副本。

后续升级只需传入新二进制，不需要再次提供邮箱。安装脚本检测到并验证 `/etc/letsencrypt/live/139.196.148.174/fullchain.pem` 和 `privkey.pem` 后，会从模板重新渲染正式证书路径；验证失败时保持原 Nginx 配置不变：

```bash
PAPER_STORAGE_BINARY=/实际路径/新版本-paper-storage ./install.sh
```

健康检查应返回 `status=ok`；磁盘使用率达到 70% 时返回 `warning`，达到 95% 时返回 `readonly`。上线前同时检查：

```bash
systemctl status paper-storage --no-pager
journalctl -u paper-storage -n 100 --no-pager
nginx -t
curl -fsS http://127.0.0.1:8081/healthz
curl -fsS https://139.196.148.174/healthz
```

### 网络与 SSH 加固

`SSH_PORT` 默认为 `22`，只接受 `1` 到 `65535` 的十进制端口。如果生产 SSH 端口不是 22，每次首次安装和后续升级都必须显式传入，例如：

```bash
SSH_PORT=2222 PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
```

脚本先审计 `ufw show added`，默认只接受 `${SSH_PORT}/tcp`、`80/tcp` 和 `443/tcp` 三类 ALLOW 规则；发现其他放行规则会在修改防火墙前中止。确认额外规则确属必要时，可显式执行：

```bash
ALLOW_EXISTING_UFW_RULES=1 SSH_PORT=2222 \
  PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
```

该开关会保留全部既有放行规则，可能扩大攻击面，必须先逐条人工核对。脚本不会执行 `ufw reset`，会先放行 SSH，再设置 `ufw default deny incoming`、`default allow outgoing`，最后放行 80/443 并启用 UFW。安装脚本不会直接关闭 SSH 密码登录。

先配置普通运维账号和 SSH 公钥，确认 SSH 公钥登录成功后，再设置：

```text
PasswordAuthentication no
PermitRootLogin prohibit-password
```

修改后先执行 `sshd -t`，保持当前会话不退出，从第二个终端验证公钥登录成功后再关闭旧会话。

### 缓存与备份

139 不接入业务域名或 Cloudflare。源站必须保留 `Cache-Control: private, no-store` 与 `Referrer-Policy: no-referrer`，不得为 `/v1/files/*`、`/v1/uploads/*` 或 `/_paper_files/*` 配置缓存；下载位置关闭访问日志，避免短时 token 落盘。

在云厂商控制台启用每日磁盘快照，至少保留 7 天。快照是灾难恢复手段，不替代每天核对数据库引用、文件数量、大小和 SHA-256。journald 日志保留 14 天；下载位置关闭访问日志，其他日志也不记录查询参数，避免短时 token 泄露。

### 更新、回滚与故障处理

安装脚本先校验输入是 Linux ELF，把新版本写入同目录 `paper-storage.new`；所有 Nginx、UFW、Swap 和 systemd 前置检查完成后，才把当前版本备份为 `paper-storage.bak` 并原子切换。重启或本机 `/healthz` 检查失败时会自动恢复旧版本、再次重启并返回失败。升级命令不需要手工创建备份：

```bash
PAPER_STORAGE_BINARY=/实际路径/新版本-paper-storage ./deploy/paper-storage/install.sh
```

正常成功后 `.bak` 会删除；健康检查失败并自动恢复后也不会残留 `.bak`。如果安装进程被断电或强制终止并留下 `.bak`，下一次安装会拒绝覆盖恢复点。先核对当前二进制和日志，再手工恢复：

```bash
mv -f /opt/sylg-paper-storage/bin/paper-storage.bak \
  /opt/sylg-paper-storage/bin/paper-storage
chown root:paper-storage /opt/sylg-paper-storage/bin/paper-storage
chmod 0755 /opt/sylg-paper-storage/bin/paper-storage
systemctl restart paper-storage
curl -fsS http://127.0.0.1:8081/healthz
```

若新版本异常，先在主服务器把 `EXAM_PAPER_STORAGE_MODE` 切为 `readonly-remote`，停止新的远端上传。已标记为 `remote` 的试卷继续从文件服务器下载，本地记录继续走主服务器。不要在回滚时删除 `/opt/sylg-paper-storage/data`、远端业务记录或 `.trash`。如果 Nginx 配置导致启动失败，使用安装脚本首次保存的 `/etc/nginx/nginx.conf.pre-sylg-paper-storage` 恢复，执行 `nginx -t` 后再 reload。
