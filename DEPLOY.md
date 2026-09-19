# SYLUlive 部署总入口

正式部署以不可变 commit SHA 为准，生产服务由 systemd 或 Docker Compose 管理。本文包含当前生产拓扑、基线要求、P3 传输规范、独立文件服务运维守则与专项文档入口；历史部署演进细节已归档到 docs/archive/。

## 当前生产拓扑

~~~text
公网 HTTPS
    │
    ▼
  Nginx ──► Go Server :8080 ──► PostgreSQL 15 / pgvector
                    ├──► Python RAG :8001
                    └──► 迁移期教务服务 :8000（按开关启用）
~~~

Go 的 8080 只允许本机或 Docker 内部访问，公网流量必须经过 Nginx。Python 教务服务不是新版客户端的默认个人教务路径。

## 部署环境要求

- 服务器操作系统：Ubuntu 20.04+
- 数据库：PostgreSQL 15 / pgvector
- 运行环境：Go 1.25.13+（`deploy.sh` 会自动处理）

## 正式发布

1. 备份 PostgreSQL，并确认回滚二进制或上一稳定 SHA 可用。
2. 在生产 .env 配置并复核 JWT、数据库、邮件、代理和安全中心变量：

~~~env
TRUSTED_PROXY_CIDRS=127.0.0.1/32
SECURITY_EVENT_HMAC_SECRET=<独立随机密钥>
SECURITY_BLOCK_ENABLED=false
SECURITY_SOURCE_ATTRIBUTION_VALID_FROM=<真实来源修复生效时间>
~~~

3. 使用最终 SHA 部署：

~~~bash
deploy-shenliyuan <commit-sha>
~~~

4. 验证 health、version、监听地址、Nginx 配置和数据库迁移。
5. 从两个公网出口验证来源指纹不同，并确认伪造 X-Forwarded-For 不生效。
6. 实际完成一次验证码发送和校验，检查安全中心事件来源不是 127.0.0.1。
7. 观察错误率、邮件队列、数据库连接和安全事件，再宣布发布完成。

部署脚本会检查安全环境变量并在冒烟失败时回滚。不要在生产运行目录执行 git pull，也不要使用旧的根目录 deploy.sh 作为正式入口。

## 图片公开上传的授权静态传输（Docker P3）

Docker 部署中的 `/uploads/` 仍然先反代到 Go 的 `ServePublic`。图片变体 worker 与 X-Accel 静态直传由 `.env` 显式配置，生产目标值均为 `true`：Go 启动时会自动为历史公开图片执行补偿任务（补建变体任务），worker 仅在 `IMAGE_VARIANT_WORKER_ENABLED=true` 时启动并消化 pending 任务；变体就绪前客户端继续回退原图，不会出现长期 404。只有 Go 根据 `files.access_scope = public` 完成授权、通过 `ResolveUploadPath` 路径校验并确认文件存在后，才会返回 `X-Accel-Redirect`。Nginx 的目标位置是 `internal`，客户端不能直接请求它。`GIN_MODE=release` 时两个开关缺失或为空会直接拒绝启动，避免漏配静默回退。

生产 `.env` 目标值（compose 对两者使用 `:?` 强制显式提供）：

~~~env
UPLOAD_DIR=/app/uploads
IMAGE_VARIANT_WORKER_ENABLED=true
UPLOAD_USE_ACCEL_REDIRECT=true
UPLOAD_ACCEL_PREFIX=/_internal/uploads/
~~~

回退开关（worker 异常或传输链路异常时使用；改为 false 后仍必须显式保留在 `.env` 中）：

~~~env
IMAGE_VARIANT_WORKER_ENABLED=false
UPLOAD_USE_ACCEL_REDIRECT=false
~~~

`docker-compose.yml` 中 `server_data` 同时挂载到 Go 的 `/app/uploads` 和 Nginx 的 `/var/lib/sylulive/uploads`，Nginx 挂载必须带 `:ro`。不要把 `exam_paper_data`、`competition_award_evidence_data` 或任何私有目录挂载到 Nginx；如果修改 `UPLOAD_DIR`，必须同步重新验证 Go 的存储路径和 Nginx alias，未完成前先把 `UPLOAD_USE_ACCEL_REDIRECT` 改回 `false` 并重启 Go。

### 部署检查与回退约束

按以下顺序执行，任一步失败都不要发布新默认值：

1. 确认 P2 worker 和 API 的原图回退逻辑已发布，pending、failed、unsupported 不会让客户端请求长期 404。
2. 历史公开图片缺宽高时（`image_pipeline_stats.sql` 的 `public_missing_dimensions` 不为 0），先跑 `server/cmd/backfill_image_metadata --dry-run` 预览、去掉参数实跑，再重启 Go，让启动期 `BackfillPublicImageVariantTasks` 按补齐后的宽高为长边 >1280 的图片补建 viewer 任务。
3. 运行 `bash scripts/image_pipeline_verify.sh` 硬门禁：`PUBLIC_URL` 与 `PRIVATE_URL` 必填；thumb/medium/viewer 轮询超时、数据库统计失败、pending 未下降、failed 超阈值、`public_without_any_variant > 0` 任一命中都会以非零退出，未通过不得发布。
4. 确认 Go 与 Nginx 使用同一公开上传共享卷，且 Nginx 对该卷只读挂载；目录中的路径只能由服务端生成。
5. 渲染 Compose 配置并检查挂载：

~~~bash
docker compose config
docker compose config | grep -E 'server_data:/app/uploads|server_data:/var/lib/sylulive/uploads:ro'
~~~

6. 校验 Nginx 配置：

~~~bash
docker compose run --rm --no-deps nginx nginx -t
~~~

7. 用测试图片验证：公开图片必须在 Go 允许后正常返回；私有图片、包含 `..` 的路径和 `/_internal/uploads/` 的外部请求都必须被拒绝。Go 拒绝时 Nginx 不得回退为静态文件。检查通过后重新创建 Go 和 Nginx 容器，并再次执行 `nginx -t`。开关只改变已通过 Go 授权的公开文件传输方式，不改变数据库权限判断，也不能让客户端访问 internal 位置。

- 私有文件始终保持 `private, no-store`，不得经 Nginx 外部静态路径或 CDN 访问。
- 发布顺序固定为 P2 worker 和 API 回退、客户端资源选择、最后发布 P3。客户端预取没有远程开关，不能把服务端开关描述成客户端预取的关闭开关。
- 回退时先停 worker，把 `UPLOAD_USE_ACCEL_REDIRECT` 改回 `false` 并重启 Go；继续返回 origin URL，保留原图和已经生成的变体。不得删除文件、批量 purge 缓存或改变私有文件权限。
- 若变体 worker 出现异常，先将 `IMAGE_VARIANT_WORKER_ENABLED` 改回 `false` 并重启 Go；保留原图和已生成变体，不删除任务记录或文件。

## 独立试卷文件服务器 (139.196.148.174)

试卷文件服务直接使用公网 IP `139.196.148.174`，不配置或复用 `sylulive.online` 业务域名。生产 TLS 证书的 SAN 必须包含 `IP Address:139.196.148.174`，客户端上传、预览和下载均直连该 IP。不得记录服务器密码到仓库、部署日志或切换报告中；聊天中曾共享过的密码应在上线前轮换。

### 构建与首次安装

在可信构建机生成 Ubuntu 24.04 可执行文件：

~~~bash
cd server
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/paper-storage ./cmd/paper_storage
~~~

把仓库和二进制放到文件服务器后，以 root 执行安装。`auto` 模式要求 Certbot 5.4 或更高版本；脚本会在需要时通过 Snap 安装新版 Certbot，先加载仅开放 80 端口 challenge 的 bootstrap 配置，完成 staging 验证和正式 IP 证书签发后才开放 443：

~~~bash
cd deploy/paper-storage
PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
~~~

脚本创建非登录用户 `paper-storage`、`0700` 数据目录、`0600` 环境文件，安装 Nginx、UFW、Certbot 和 systemd 单元，并在现有 Swap 小于 2 GiB 时新增 Swap。活动 Swap 不会被停用或重建；非活动文件会同时通过 `blkid` 与 `file` 校验签名，损坏文件使用 `.new` 完整创建并同步后原子替换。符号链接和非普通文件会被拒绝。生产证书不存在、私钥不匹配、有效期不足、SAN 错误或证书链不受系统信任时，脚本会拒绝渲染正式 Nginx 配置，不会回退 snakeoil 或自签证书。

生成两把不同的密钥，只写入 `/etc/sylg-paper-storage.env`：

~~~bash
openssl rand -hex 32
openssl rand -hex 32
~~~

第一把同时配置为主服务器的 `EXAM_PAPER_STORAGE_SIGNING_SECRET` 和文件服务器的 `PAPER_STORAGE_SIGNING_SECRET`；第二把同时配置为主服务器的 `EXAM_PAPER_STORAGE_RECEIPT_SECRET` 和文件服务器的 `PAPER_STORAGE_RECEIPT_SECRET`。两把密钥不得相同，也不得提交到 Git。

156 主服务器切换远端存储时使用以下配置；两个密钥值分别与 139 对应配置一致，但彼此必须不同：

~~~env
EXAM_PAPER_STORAGE_MODE=remote
EXAM_PAPER_STORAGE_BASE_URL=https://139.196.148.174
EXAM_PAPER_STORAGE_SIGNING_SECRET=<高强度随机密钥A>
EXAM_PAPER_STORAGE_RECEIPT_SECRET=<高强度随机密钥B>
~~~

写入真实密钥、确认公网 80/443 已放行后，首次签发正式证书时提供联系人邮箱；Certbot 会申请受系统信任的短期 IP 证书并启用自动续期 timer，deploy hook 只会在 `nginx -t` 成功后 reload：

~~~bash
LETSENCRYPT_EMAIL=管理员邮箱 PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
certbot renew --dry-run
openssl s_client -connect 139.196.148.174:443 -servername 139.196.148.174 -showcerts
curl -fsS https://139.196.148.174/healthz
~~~

证书由外部系统管理时，必须同时显式指定证书和私钥；脚本仍会执行全部证书校验：

~~~bash
PAPER_STORAGE_ACME_MODE=external \
PAPER_STORAGE_TLS_CERT_PATH=/受控路径/fullchain.pem \
PAPER_STORAGE_TLS_KEY_PATH=/受控路径/privkey.pem \
PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
~~~

### 历史试卷文件迁移

迁移命令只处理仍有效的 `pending`、`published` 本地试卷记录。它会流式读取主服务器上的原文件，重新计算实际大小和 SHA-256，再通过带 `metadata` scope 的短时授权读取文件服务器元数据；数据库记录、本地文件和远端文件的 key、大小、SHA-256 全部一致时，才允许把 `storage_backend` 条件更新为 `remote`。命令不会重新解析或解密 PDF，不会删除源文件，也不会输出密钥或授权 token。

先在文件服务器准备目标目录，再从主服务器复制。SSH 用户、端口和密钥路径按生产实际值填写，不要把密码写入脚本或命令历史：

~~~bash
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
~~~

`--checksum` 会按内容核对源和目标。不得复制 `.trash`、`.pending`、`.sessions` 或迁移期间产生的临时文件；目标端权限修复命令必须在文件服务器本机执行。

复制后先运行默认 dry-run。命令从主服务器 `.env` 读取 `DSN`、`EXAM_PAPER_DIR`、`EXAM_PAPER_STORAGE_BASE_URL` 和签名密钥；生产环境应已配置文件服务地址 `https://139.196.148.174`。可用 `--id` 单独演练，也可用 `--page-size` 调整批量分页：

~~~bash
cd /opt/shenliyuan-src/server

# 默认即 dry-run；显式写出便于操作审计
go run ./cmd/migrate_exam_papers_remote --dry-run
go run ./cmd/migrate_exam_papers_remote --dry-run --id <试卷ID>
~~~

确认报告中 `failed=0`，并人工核对待迁移数量、源文件、目标文件两份副本后，再显式执行正式更新：

~~~bash
go run ./cmd/migrate_exam_papers_remote --apply
# 或逐条切换
go run ./cmd/migrate_exam_papers_remote --apply --id <试卷ID>
~~~

任意单条文件缺失、符号链接、路径非法、远端 metadata 缺失或不一致都会保留该记录为 `local`；批量任务会继续检查其余记录，最终以非零状态退出并汇总 `failed`。并发修改过的记录也不会被误标为远端。修正文件后可安全重跑；已是 `remote` 的记录会被跳过。

迁移完成后主服务器源文件以只读方式保留至少 7 天，在备份和线上下载核验稳定前不得删除。发生异常时，把主服务器 `EXAM_PAPER_STORAGE_MODE` 设为 `readonly-remote` 并重启，可停止新远端上传；已标记为 `remote` 的记录仍从文件服务器读取，未迁移的 `local` 记录仍使用主服务器副本。该开关不会自动把数据库标记改回 `local`，因此不要依赖它将已迁移记录切回旧副本。

后续升级只需传入新二进制，不需要再次提供邮箱。安装脚本检测到并验证 `/etc/letsencrypt/live/139.196.148.174/fullchain.pem` 和 `privkey.pem` 后，会从模板重新渲染正式证书路径；验证失败时保持原 Nginx 配置不变：

~~~bash
PAPER_STORAGE_BINARY=/实际路径/新版本-paper-storage ./install.sh
~~~

健康检查应返回 `status=ok`；磁盘使用率达到 70% 时返回 `warning`，达到 95% 时返回 `readonly`。上线前同时检查：

~~~bash
systemctl status paper-storage --no-pager
journalctl -u paper-storage -n 100 --no-pager
nginx -t
curl -fsS http://127.0.0.1:8081/healthz
curl -fsS https://139.196.148.174/healthz
~~~

### 网络与 SSH 加固

`SSH_PORT` 默认为 `22`，只接受 `1` 到 `65535` 的十进制端口。如果生产 SSH 端口不是 22，每次首次安装和后续升级都必须显式传入，例如：

~~~bash
SSH_PORT=2222 PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
~~~

脚本先审计 `ufw show added`，默认只接受 `${SSH_PORT}/tcp`、`80/tcp` 和 `443/tcp` 三类 ALLOW 规则；发现其他放行规则会在修改防火墙前中止。确认额外规则确属必要时，可显式执行：

~~~bash
ALLOW_EXISTING_UFW_RULES=1 SSH_PORT=2222 \
  PAPER_STORAGE_BINARY=/实际路径/paper-storage ./install.sh
~~~

该开关会保留全部既有放行规则，可能扩大攻击面，必须先逐条人工核对。脚本不会执行 `ufw reset`，会先放行 SSH，再设置 `ufw default deny incoming`、`default allow outgoing`，最后放行 80/443 并启用 UFW。安装脚本不会直接关闭 SSH 密码登录。

先配置普通运维账号和 SSH 公钥，确认 SSH 公钥登录成功后，再设置：

~~~text
PasswordAuthentication no
PermitRootLogin prohibit-password
~~~

修改后先执行 `sshd -t`，保持当前会话不退出，从第二个终端验证公钥登录成功后再关闭旧会话。

### 缓存与备份

139 不接入业务域名或 Cloudflare。源站必须保留 `Cache-Control: private, no-store` 与 `Referrer-Policy: no-referrer`，不得为 `/v1/files/*`、`/v1/uploads/*` 或 `/_paper_files/*` 配置缓存；下载位置关闭访问日志，避免短时 token 落盘。

在云厂商控制台启用每日磁盘快照，至少保留 7 天。快照是灾难恢复手段，不替代每天核对数据库引用、文件数量、大小和 SHA-256。journald 日志保留 14 天；下载位置关闭访问日志，其他日志也不记录查询参数，避免短时 token 泄露。

### 更新、回滚与故障处理

安装脚本先校验输入是 Linux ELF，把新版本写入同目录 `paper-storage.new`；所有 Nginx、UFW、Swap 和 systemd 前置检查完成后，才把当前版本备份为 `paper-storage.bak` 并原子切换。重启或本机 `/healthz` 检查失败时会自动恢复旧版本、再次重启并返回失败。升级命令不需要手工创建备份：

~~~bash
PAPER_STORAGE_BINARY=/实际路径/新版本-paper-storage ./deploy/paper-storage/install.sh
~~~

正常成功后 `.bak` 会删除；健康检查失败并自动恢复后也不会残留 `.bak`。如果安装进程被断电或强制终止并留下 `.bak`，下一次安装会拒绝覆盖恢复点。先核对当前二进制和日志，再手工恢复：

~~~bash
mv -f /opt/sylg-paper-storage/bin/paper-storage.bak \
  /opt/sylg-paper-storage/bin/paper-storage
chown root:paper-storage /opt/sylg-paper-storage/bin/paper-storage
chmod 0755 /opt/sylg-paper-storage/bin/paper-storage
systemctl restart paper-storage
curl -fsS http://127.0.0.1:8081/healthz
~~~

若新版本异常，先在主服务器把 `EXAM_PAPER_STORAGE_MODE` 切为 `readonly-remote`，停止新的远端上传。已标记为 `remote` 的试卷继续从文件服务器下载，本地记录继续走主服务器。不要在回滚时删除 `/opt/sylg-paper-storage/data`、远端业务记录或 `.trash`。如果 Nginx 配置导致启动失败，使用安装脚本首次保存的 `/etc/nginx/nginx.conf.pre-sylg-paper-storage` 恢复，执行 `nginx -t` 后再 reload。

## 专项文档

- [Go 后端部署](./docs/ops/backend.md)
- [官网静态站部署](./docs/ops/website.md)
- [Android 发布](./docs/ops/app-release.md)
- [RAG 部署](./docs/ops/rag.md)
- [迁移期教务服务](./docs/ops/legacy-edu.md)
- [回滚与验收](./docs/ops/rollback.md)
- [部署脚本](./deploy/deploy-shenliyuan)
- [Docker Compose](./docker-compose.yml)

## 发布纪律

- 生产部署必须记录 Git SHA、数据库迁移结果和健康检查结果。
- 不在 README、日志或工单中写入学校密码、Cookie、Token 或个人教务原始数据。
- 生产开关改变学校权限、AI、MCP、上传或安全封禁行为时，必须经过单独的发布审批。
