# 2026-10-15 登录限流故障回退复查与修复

本记录承接 [第一轮部署验收](2026-10-15-auth-security-deployment.md)，范围为登录限流表查询错误时的内存回退，以及生产只读复核。维护者此前明确授权测试、推送和部署；本轮保持严格限流、来源封禁、SSH 和数据库权限的原配置。

## 缺陷与修复

基准代码为 54a316430，生产基准为 a67cd603b。故障注入只针对隔离测试数据库中的 login_throttle_records 查询，用户表保持可读：失败计数可回退到内存，但 loginLock 的查询错误分支返回未锁定。原始回归测试在账号/IP 两种场景均失败，正确密码返回 200，并产生两条刷新会话，复现了复查中提出的问题。

修复提交为 `0d02aecc995a4f1305098116da420455841d7cc8`，仅将非 ErrRecordNotFound 的查询错误分支改为 currentLoginLock(scope, now)。数据库读取成功和无记录时仍以 PostgreSQL 共享状态为准。未更改锁定阈值，也未把进程内降级称为跨实例防护。

新增回归验证：

- 账号三次失败、来源十次失败在数据库异常时建立内存锁；正确和错误密码均在用户查询及 bcrypt 前返回 429，并带 Retry-After。
- 锁定期间不创建刷新会话；锁到期可解除。
- 数据库无记录、未锁定记录和有锁记录保持共享状态优先，不复活陈旧内存锁。
- 同一故障场景纳入已受强制执行门禁约束的独立 PostgreSQL 集成测试。

## 验证证据

- Windows Go 1.26.9，本地针对性测试、认证回退竞态测试、全量 go test -p 1 ./...、go vet ./...、go build ./... 均通过。
- govulncheck：可达漏洞 0、导入包漏洞 0，仍有未被代码调用的既有模块公告。首次未显式选择 Strawberry GCC 导致 CGO 包加载失败，补齐同一验证环境的 CC/CGO 配置后通过；没有删除 CGO 测试。
- [发布 CI 38673363941](https://github.com/zhouwu97/SYLUlive/actions/runs/38673363941)：12 个 jobs 全部 success，包括 Go、PostgreSQL 故障回退、迁移、Python、Web、浏览器、Flutter 全量测试与 APK 构建。
- [安全扫描 38673363894](https://github.com/zhouwu97/SYLUlive/actions/runs/38673363894)：六项全部 success。
- workflow_conclusion=success，evidence_status=verified，release_decision=passed（本轮 Go 回退修复范围）。启动服务端发布时独立客户端任务仍运行，先记录为 partial；最终由当前维护者核验完整 CI、恢复演练与线上结果后放行。

## 生产复核与告警闭环

维护者于本轮明确确认：两个指定运维邮箱均已收到上一轮测试邮件。该确认补齐收件箱送达证据，生产启动日志也明确显示 recipients=2。未为了验收而伪造真实高危攻击或发送新的通知。

发布前通过 SSH 独立读取回环 /version、公网 /api/version，均为 a67cd603b；shenliyuan、nginx active，源码目录干净。第一轮发布以来未见成功审计写入失败或 panic。生产 Nginx 精确登录位置仍是 dry-run on，XFF 覆盖为 remote_addr；SECURITY_BLOCK_ENABLED=false。

SSH 有效配置仍为密码认证开启、公钥认证开启、root 密码登录关闭；ubuntu 有一条授权公钥，但本轮没有证明维护者持有该私钥并可用新会话登录。数据库实际 DSN 角色为 postgres，具有超级用户、建库和建角色权限；代码启动自动迁移仍与业务进程耦合。直接关闭 SSH 密码或直接撤销数据库 DDL 权限均不满足恢复前置条件，本轮只读核实并记录后续专项。

## 发布、备份与恢复

正式入口为固定提交中的 deploy/deploy-shenliyuan，保留上一二进制并执行版本与受保护路由硬门禁。额外编排在真实 HTTPS 认证冒烟失败时回退上一二进制。

独立受控目录 `/var/lib/sylulive-release/20261015-auth-throttle-fallback/` 保存当前二进制、生产环境、Nginx 配置和完整数据库快照。目录 0700、敏感文件 0600；本轮快照 SHA-256 为 `4fa4784ee8e553e07f3b7bccca88cce57867bd5ae0843561f8ed248724a87061`，pg_restore -l 确认可读。本轮另将新快照完整恢复到专用 sylulive_throttle_restore_20261015_test，确认表和数据可读取后回收该演练库；未恢复或清空生产库。

本轮于 2026-10-15 10:59:42（UTC+08）完成部署，构建时间 2026-10-15T02:59:15Z。运行 SHA 为 0d02aecc995a4f1305098116da420455841d7cc8。读取 systemd MainPID 对应的 /proc/PID/exe，摘要与磁盘二进制一致，为 d31e783f14df9c3e4cc52bbb3cc8f1416416e566111b716bcff29ed4fd94bd77；回环与公网版本接口均匹配该 SHA，health=ok。正式脚本保留上一二进制 /opt/shenliyuan/shenliyuan.bak.20261015_105932，受控目录另有备份。

公网 HTTPS 冒烟通过：Cookie 登录与刷新 JSON 不含令牌；Cookie 为 Secure/HttpOnly；原生 Bearer 登录兼容；退出当前会话后资料 401，另一会话仍 200；非法跨站写入返回 403；写入两条成功审计；伪造 XFF 不改变来源。测试账号通过正常注销接口回收，旧令牌变为 401。Nginx、环境文件及原安全开关哈希与本轮备份一致。

切换期间 10:59:35–10:59:37 出现 3 次 5xx，单实例重启并非无中断发布。最终观察 819 秒、434 个请求没有新增 5xx，未见审计写入失败、panic 或服务自动重启。故障注入只在隔离测试执行，未在生产数据库制造故障。线上过程与 JSON 证据保存在本轮受控发布目录，未提交日志、账号或令牌。

## 主线同步与剩余事项

已从 main 单独移植安全提交建立 [草稿 PR #77](https://github.com/zhouwu97/SYLUlive/pull/77)，37 个文件的差异均属于安全修复及其证据；客户端只变更图片依赖约束。服务端、部署和 Nginx 内容与本轮发布分支一致。PR 拥有独立 CI，保持草稿并等待主线审查；本轮未合并 main。提交移植后的 SHA 不等同于生产运行 SHA。

受影响账号名单与钓鱼页面提交事实仍需用户或原始证据确认，不能用指定来源的失败登录线索认定账号接管。本轮未批量改密或下线真实用户。数据库迁移/业务权限拆分、SSH 密钥恢复验证、校园共享出口限流阈值、Passkey 与用户会话管理继续按独立范围处理。
