# 2026-10-15 登录安全部署验收

本文承接 [上线前审计记录](2026-10-15-auth-security-remediation.md)，记录本轮维护者授权的推送、测试和生产发布。范围为 Go 认证、安全审计、运维告警及 systemd Nginx 登录观察规则；不发布新的 Flutter 安装包或 React Web 站点。

## 提交与授权

- 安全修复提交：`dd5e098ac0bd863697b067ae40cfe0bcc7149f39`。
- 候选发布提交：`a67cd603b1e94c98b39602f829fddbb5c1b23327`。
- 分支：`codex/auth-security-20261015`；保留原工作区中的其他修改，未强推或合并主分支。
- 维护者明确授权：“推送自己测试看看然后部署吧”；收件人由维护者另行提供，真实邮箱及 SMTP 凭据不进入仓库，只在受控运维环境使用。
- 责任人：当前维护者；执行范围按 [登录安全运维入口](../ops/auth-security.md) 和 [正式部署入口](../../DEPLOY.md)。

## 首次失败与修正

首次候选的 [CI 38663693682](https://github.com/zhouwu97/SYLUlive/actions/runs/38663693682) 整体为 failure。Go、PostgreSQL、迁移、Python、Web 与浏览器任务通过，Flutter 测试出现 125 个编译加载失败：重新解析到 image 4.11.0 后使用 archive 4.2.0 未提供的 decodeLazy。该问题属于既有客户端依赖约束兼容，不是服务端认证测试失败。

修正只将 image 从 ^4.9.2 固定为锁文件原有的 4.9.2，保留 archive 4.2.0 和原锁文件，不修改 UI 或测试断言。Windows Flutter 3.41.8 上的图片压缩、课表归档导出、评论输入测试共 39 个通过。完整 CI 结果与本轮实际部署证据如下；首次 failure 不被后续通过覆盖。


## 发布门禁

- 最终提交的 [CI 38665372692](https://github.com/zhouwu97/SYLUlive/actions/runs/38665372692)：workflow_conclusion=success，evidence_status=verified；12 个 jobs 全部通过，包括 Flutter 全量测试和 Android APK 构建冒烟。
- [Security Scans 38665372688](https://github.com/zhouwu97/SYLUlive/actions/runs/38665372688)：workflow_conclusion=success，evidence_status=verified；Gitleaks、govulncheck、两个 pip-audit、Go/Python CodeQL 六项全部通过。
- 本轮 Go、PostgreSQL、迁移、发布脚本、Python、Web 构建/单测/浏览器必要任务通过后启动服务端发布；启动时独立 Flutter 全量任务仍运行，发布记录为 partial。客户端不发布安装包；当前维护者已在本轮结束前复查最终完整 CI，结果全部通过。
- release_decision=passed（仅限本轮 Go/Nginx 范围）；最终完整 CI、生产部署和线上专项冒烟均成功，维护者授权范围内放行。CI 原始 JSON、启动时快照、脚本日志及后续核验只保存于受限运维目录。

## 备份与正式入口

发布前保存了二进制、生产环境文件、Nginx 原配置与完整 PostgreSQL 快照，全部位于服务器 `/var/lib/sylulive-release/20261015-auth-security/`，目录 0700，敏感文件 0600。数据库快照 SHA-256：`a798f3ee83985a9d4cf46605beadc32757130fbf474fac9886da3d786e999a25`。

快照已恢复到独立、可丢弃的 `sylulive_auth_restore_20261015_test`，确认表与数据可读取后删除演练库。生产数据库未被恢复或清空。先前事故证据目录继续保留，没有覆盖原件。

Go 1.26.9 官方 linux/amd64 工具链校验后安装在独立目录，不替换原宿主机 Go。使用固定提交中的 `deploy/deploy-shenliyuan <完整 SHA>` 正式入口完成编译、原子二进制替换、systemd 重启和七条受保护治理路由冒烟。额外编排在 Nginx 应用或生产认证冒烟失败时恢复旧二进制、环境和 Nginx 配置。

实际结果：

- 发布时间：2026-10-15 09:28:57（UTC+08），构建时间 2026-10-15T01:27:03Z。
- 运行 SHA：`a67cd603b1e94c98b39602f829fddbb5c1b23327`，源码目录干净，systemd 与 Nginx active。
- 运行二进制 SHA-256：`5d70b74bc8b0b7b72e2567599044bde1285306b2c51493a636833bf494060619`。
- 上一稳定 SHA：`6e8062e8d3a9ed2682496149d6e572d57a16b861`。
- 正式脚本保留回滚文件 `/opt/shenliyuan/shenliyuan.bak.20261015_092848`；受限发布目录另行保留原版副本。
- 完整 Nginx 候选与实际配置均通过 nginx -t；专用登录规则已 reload，原站点及其他代理配置保留。
- 单实例重启在 09:28:48–09:28:54（UTC+08）产生 99 次 502，影响窗口约 6 秒；不能将本轮发布描述为无中断切换。恢复后专项观察未见新增 5xx，服务没有自动重启循环。后续若需避免此窗口，应单独设计健康检查通过后切换流量的多实例发布。

## 线上业务验收

前置条件为保留正常用户数据，使用两个唯一的普通角色临时测试账号，邮箱位于保留的 example.invalid 域，随机密码只用于本轮验证。经过真实公网 HTTPS 的操作结果如下：

| 操作与预期 | 实际 | 证据 |
| --- | --- | --- |
| Cookie 登录成功，JSON 不含访问/刷新令牌 | 200，字段均缺省 | production-auth-smoke.json |
| 登录 Cookie 均为 Secure、HttpOnly、/api | 两枚 Cookie 均符合 | production-auth-smoke.json |
| Cookie 读取资料与刷新继续可用 | 均 200；刷新 JSON 不含令牌 | production-auth-smoke.json |
| 无 Origin 的原生 Bearer 登录与资料读取 | 均 200，保留令牌响应契约 | production-auth-smoke.json |
| 退出当前 Cookie 会话 | 退出 200，后续资料 401 | production-auth-smoke.json |
| 当前会话退出不撤销另一设备会话 | 另一 Bearer 会话仍 200 | production-auth-smoke.json |
| 非法跨站浏览器写请求 | 403，origin_rejected | production-auth-smoke.json |
| 两次成功登录分别写流水 | 两条 login_success | production-auth-smoke.json |
| 伪造 XFF 不改变来源 | 同一出口的来源摘要一致 | production-auth-smoke.json |
| 两个真实网络出口可区分 | 两条成功流水、两个来源摘要 | two-source-smoke.json |
| 测试结束回收账号和会话 | 第一账号通过正常注销接口处理、令牌变 401；第二账号精确停用并撤销会话；活跃测试账号为零 | production-auth-smoke.json、two-source-smoke.json |
| 公网版本与回环健康检查 | status=ok，Git SHA 匹配 | post-deploy-verification.json |

密码重置和其他账号/IP 防护保留由本地及 PostgreSQL 专项测试验证；未对真实生产用户执行找回、批量重置或撤销。生产环境不发送找回邮件来替代隔离测试。

## 运行状态与边界

- `SECURITY_ALERT_EMAILS` 已配置两个经维护者确认的邮箱；服务启动明确记录 SECURITY_ALERTS_ENABLED recipients=2，环境文件仍为 root:shenliyuan、0640。STARTTLS 测试 SMTP 接受两位收件人；收件箱到账与垃圾邮件分类仍待收件端确认。本轮未伪造真实高危攻击触发告警。
- Nginx 登录观察区为 30r/m、burst=20、dry-run on。额外登录日志仅含时间、请求 ID、状态和限流状态。不能将该观察模式写成新增严格限流已经生效。
- `SECURITY_BLOCK_ENABLED=false` 保留；先完成真实来源与共享校园出口阈值验收，再另行决定启用。后端既有账号/IP 失败锁定继续工作。
- 最终发布后 920 秒内采样 1940 条 Nginx 请求，没有 5xx；登录日志含四次 200、一次预期跨站 403。成功审计写入失败和 panic 计数均为零。短时观察不能证明长期无故障。
- Go 8080、PostgreSQL 5432、迁移期 Python 8000 仍绑定回环。外部端口应用握手未成功；本地网络存在连接代理，单纯 TCP connect 返回成功不作为公网暴露证据。
- 生产没有 React Web 站点的实际部署目录。本轮将 Web Cookie 请求头修复推送并完成构建及浏览器测试，未把不存在的站点发布流程写成已上线。
- 数据库业务连接超级用户拆分、Passkey、用户设备会话管理、Cloudflare 源站策略和服务器凭据轮换未包含在本次增量发布中。现有事件调查不构成服务器已失陷的证明。

## 回滚入口

本轮未改变表结构或删除已有安全记录。若需恢复，按 [登录安全运维入口](../ops/auth-security.md) 先恢复已备份 Nginx 站点并移除本轮新增的精确 auth-rate 片段，通过 nginx -t 后 reload；恢复受限目录的生产环境与上一稳定二进制，重启 shenliyuan，重新验证 health/version 和鉴权路径。原始证据与数据库快照继续保留，不通过全库恢复覆盖发布后正常用户写入。

正式脚本具备冒烟失败自动回滚，额外编排具备配置与认证失败恢复；本次实际部署未触发回滚。已完成数据库恢复演练和回滚配置检查，未为了演练中断线上稳定服务。
