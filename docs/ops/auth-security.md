# 登录安全修复与发布验收

本入口维护登录安全配置、取证与回滚步骤。正式部署仍以 [DEPLOY.md](../../DEPLOY.md) 的不可变提交发布流程为准；一次性事件结论保存在 `docs/reports/`。

## 认证契约

- Web 所有同源 API 请求，包括独立刷新请求，固定声明 `X-Auth-Transport: cookie`。登录与刷新响应不包含访问令牌或刷新令牌，凭据由 HttpOnly Cookie 传输。
- 原生客户端沿用原有 Bearer 响应契约。无 Origin 的原生请求可用；浏览器写请求必须来自同源或 `CORS_ALLOW_ORIGINS` 中精确登记的可信 Origin。CORS 与写请求校验共同生效，不能用“浏览器读不到响应”替代拒绝写入。
- 重置密码后只清理该用户真实可用的邮箱、历史登录别名和兼容 QQ 的账号锁定。按登录解析逻辑验证唯一归属；其他用户、歧义别名和来源 IP 的失败计数不清除。数据库与故障回退期间的内存计数一并处理。
- `account_security_audit_logs` 每次成功登录保存一条 `login_success` 流水，包含请求 ID、时间、账号 ID、HMAC 来源与设备摘要、会话族摘要。安全中心的同名事件仍按五分钟聚合，不能当作逐条流水。
- `login_new_device` 是普通账号的观察记录；`admin_login_new_device` 为高危待处置事件，走既有告警冷却、预算和重试通道。UA 和安装标识可伪造，新设备检测不是身份认证，也不能据此证明账号被盗。没有既有设备历史或没有指纹时不作异常判定。
- 成功流水和安全中心聚合事件保留 90 天；事故证据必须另行保全，不能依赖滚动清理中的在线表。数据字段与期限见 [隐私台账](../privacy-data-inventory.md) 和 [留存台账](../retention-and-backup-inventory.md)。

## 变更前的现场保存

在受控运维目录保留 Nginx 当前及轮转日志、systemd Journal、数据库安全事件与刷新会话记录、有效 Nginx 配置、环境配置和当前二进制。目录权限设为 0700，文件权限为 0600；环境文件与数据库备份含敏感信息，只留在服务器或受控加密备份，不提交 Git、不粘贴聊天。

保存 UTC 与当地时间、机器同步状态、二进制 SHA-256、`/version` 的 Git SHA 和备份校验值。活动日志可能继续增长，读取后的哈希只是该时点观察，不能替代快照副本。数据库导出应使用一致性快照，并记下起止时间。原始证据不覆盖、不删除。

只读初筛查询可在 `BEGIN READ ONLY` 事务中执行。安全事件的 HMAC 来源摘要与刷新会话的普通 SHA256 来源摘要不能直接 JOIN；已从可信原始日志确认的来源才可本机计算匹配摘要。成功登录返回 200 或存在刷新会话，也需要结合账号归属与用户确认判断。

## Nginx 专用登录规则

systemd 部署使用两个独立片段：

1. 将 `nginx/login-security-http.conf` include 到 `http` 上下文一次。
2. 将 `nginx/login-security-location.conf` include 到实际业务 HTTPS `server`，保留站点其他规则。
3. 原 `location /api/` 的额外自定义日志、请求体限制、超时或访问控制若适用于登录，必须同步保留在新的精确位置。先对候选完整配置运行 `nginx -t`，通过后才 reload。

systemd 模板以 30r/m、burst=20 和 `limit_req_dry_run on` 起步。登录额外访问日志可在 `http` 定义仅含时间、请求 ID、状态和 `$limit_req_status` 的格式，在精确登录位置引用；不要记录请求体、账号、Cookie 或 Token。dry-run 期间超额状态为 `REJECTED_DRY_RUN`，不会拒绝登录。真实来源和校园共享出口流量验收后，才可明确批准关闭 dry-run。

Docker 的 `nginx/docker.conf` 已有通用防洪保护，专用 `login_ip` zone 初始保持 30r/s、burst=60 和现有连接上限；超额响应统一为 429。Nginx 的 `limit_req_dry_run` 会作用于该位置的所有 limit_req zone，不能在保留通用 zone 的同时假设只有新 zone 处于观察态，也不能静默取消原防洪能力。Docker 的登录配额进一步收紧需单独流量验证。

两种模板都将 `X-Forwarded-For` 替换为 Nginx 识别的 `$remote_addr`。Go 可信代理必须匹配实际拓扑；systemd 与容器配置不能互相照搬。使用 CDN 时先验证 CDN 网段与真实 IP 还原，避免把共享 CDN 出口当作用户。

## 告警配置与测试

`SECURITY_ALERT_EMAILS` 配置经维护者确认的收件人，多个邮箱以逗号分隔。SMTP 沿用生产 `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER`、`SMTP_PASS`、`SMTP_FROM`，不得把凭据写入仓库。

先验证真实 STARTTLS 与投递。测试邮件主题明确标注“安全告警通道测试”，不伪造真实攻击或写入生产安全事件。SMTP 接受邮件不等于收件箱已收到；收件端还要确认到账和垃圾邮件分类。设置收件人后随已批准版本重启，核查告警健康状态；不能把一次独立 SMTP 测试称为持续告警已经启用。

## 发布门禁与恢复

此类改动涉及认证和生产控制，按 R2/R3 执行。最低证据包括：

- 错误密码限流、正确密码创建会话，SQL 探测输入只作为普通参数；
- 有效与无效邮箱重置、邮箱和历史别名恢复、旧令牌失效、其他账号与共享来源限制保留；
- Cookie 登录与刷新不暴露令牌，原生 Bearer 契约兼容，非法 Origin 返回 403；
- 独立 PostgreSQL 测试库验证，认证与告警竞态测试，真实浏览器恢复链路；
- Go 模块测试、vet、build、govulncheck，Web check/test/build，Nginx 完整候选配置检验；
- 正式 CI 安全证据，包括 Gitleaks 与两个 Python pip-audit matrix jobs。未执行或失败不能填为成功。

生产 Go 构建最低版本为 1.26.9。通过正式发布入口部署固定 SHA，保留上一二进制与 Nginx 配置；部署后验证 `/health`、`/version`、回环监听、登录与刷新、错误恢复、安全流水和实际告警。

回滚先恢复上一 Nginx 配置并 `nginx -t`，再按正式部署入口恢复上一稳定二进制。此轮复用已有表结构，不需要删除审计或刷新会话表。回滚代码不能恢复已经因密码重置失效的凭据，也不能恢复滚动清理已删除的记录，事故证据必须提前另行保存。

数据库业务账号与迁移账号拆分、Passkey、用户设备会话管理、Cloudflare 源站保护属于独立变更，按实际拓扑、接口兼容和专项验收发布，不直接混入本轮登录缺陷修复。
