# SYLUlive 部署总入口

正式部署以不可变 commit SHA 为准，生产服务由 systemd 或 Docker Compose 管理。本文只保留当前生产拓扑、发布顺序和专项文档入口；历史部署细节已归档到 docs/archive/。

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
