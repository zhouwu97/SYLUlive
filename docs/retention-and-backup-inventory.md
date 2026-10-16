# 保存、备份与日志台账

| 项目 | 位置 | 保存期限 | 删除/覆盖方式 | 当前状态 |
|---|---|---|---|---|
| PostgreSQL 主库 | TODO | TODO | 账号注销、业务删除、备份轮换 | 待核验 |
| PostgreSQL 备份 | TODO | TODO | 备份轮换和到期销毁 | TODO |
| `uploads/` | 服务器/对象存储 | TODO | 内容删除与备份轮换 | 待核验 |
| Caddy/Nginx 日志 | TODO | TODO | 日志轮换 | 待核验 |
| systemd/Go/Python 日志 | TODO | TODO | 日志轮换、敏感字段脱敏 | 待核验 |
| 成功登录逐条流水及安全中心聚合事件 | PostgreSQL `account_security_audit_logs`（仅 `login_success`）、`security_events` | 90 天 | 服务端定时 `PurgeSecurityData`；事故保全副本按专门事件记录管理 | 仅保留脱敏摘要，其他账号安全审计沿用原策略 |
| 个人信息请求记录 | PostgreSQL | 按法定/治理义务确定 | 管理员处理与到期归档 | 已有模型，期限 TODO |
| 教务凭证清理任务 | PostgreSQL + Python 服务 | 直到成功或人工处置 | 任务重试、审计结果 | 已有模型 |

| 用户主动导出的课表/考试 JSON | Android 公共 `Download/沈理校园/课表存档`、`考试存档`；旧版为用户选择位置 | 用户自行保留 | 文件管理器删除；App 内存档删除、退出或卸载不清理公共副本 | 不包含教务凭据；保存成功后才提示实际路径 |
| 存档分享临时副本 | App 临时目录 `academic-exports` | 随系统缓存清理或卸载 | 系统缓存清理或卸载 | 仅用户主动保存/导出时生成，主动分享时发送 |
