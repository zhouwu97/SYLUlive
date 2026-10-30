# 保存、备份与日志台账

| 项目 | 位置 | 保存期限 | 删除/覆盖方式 | 当前状态 |
|---|---|---|---|---|
| PostgreSQL 主库 | TODO | TODO | 账号注销、业务删除、备份轮换 | 待核验 |
| PostgreSQL 备份 | TODO | TODO | 备份轮换和到期销毁 | TODO |
| `uploads/` | 服务器/对象存储 | TODO | 内容删除与备份轮换 | 待核验 |
| Caddy/Nginx 日志 | TODO | TODO | 日志轮换 | 待核验 |
| systemd/Go/Python 日志 | TODO | TODO | 日志轮换、敏感字段脱敏 | 待核验 |
| 成功登录逐条流水及安全中心聚合事件 | PostgreSQL `account_security_audit_logs`（仅 `login_success`）、`security_events` | 90 天 | 服务端定时 `PurgeSecurityData`；事故保全副本按专门事件记录管理 | 普通审计保留脱敏摘要，需处置预警附来源 IP 密文；密文随事件一并到期删除，其他账号安全审计沿用原策略 |
| 个人信息请求记录 | PostgreSQL | 按法定/治理义务确定 | 管理员处理与到期归档 | 已有模型，期限 TODO |
| 教务凭证清理任务 | PostgreSQL + Python 服务 | 直到成功或人工处置 | 任务重试、审计结果 | 已有模型 |
| 社区 AI 工具审计与相关回答 | PostgreSQL `ai_tool_calls` 及现有会话/Run 表 | 当前沿用会话生命周期；未建立社区来源专项 TTL | 用户删除会话时清理所属 Run 与工具审计；来源删除尚未自动级联历史副本 | 新社区读取开关默认关闭；生产开放前须完成来源失效、运行中撤权和留存验收，不能将 `expires_at` 视为自动清理 |
| AstrBot 设备请求和确认 nonce 摘要 | `integration_device_requests` | 请求10分钟，过期24小时后删除 | 服务启动及每6小时 `Purge`，不依赖功能开关 | 不保存原始设备 secret；未正式上线 |
| AstrBot 凭证摘要 | `integration_credentials` | access 10分钟；refresh闲置7天、绝对30天 | access过期删除；refresh摘要保留至绝对期限以检测旧值重用；每6小时清理 | 无原始凭证；注销/撤权即拒绝，不等清理 |
| AstrBot 草稿/动作 | `integration_actions` | 待确认72小时，动作元数据到草稿到期30天后 | 完成/拒绝/撤权立即清正文与确认 nonce，过期后6小时内清正文；保留幂等摘要与真实结果 | 来源隐藏/改写阻止后续读取/发布，不宣称能撤回已外发数据 |
| AstrBot 授权与审计 | `integration_bindings`、`integration_audits` | 有效授权直到撤销；撤销后180天、审计180天 | 每6小时清理 | 审计无草稿正文；用户注销/身份换绑同步撤销并清草稿 |
| 集成限流桶摘要 | `integration_rate_buckets` | 不超过桶有效期加6小时 | `Purge` 清理过期桶 | 数据库原子限流，摘要不可视为匿名化 |
| 插件本机授权 | OS 凭据库或进程内存；插件数据目录只存随机安装 ID | 用户断开或凭证失效；无 OS 安全后端时重启即丢内存 | 服务端撤销阻断后续请求；本机凭据库删除 | 只接受系统安全后端；不保存到插件设置和模型记忆 |

| 用户主动导出的课表/考试 JSON | Android 公共 `Download/沈理校园/课表存档`、`考试存档`；旧版为用户选择位置 | 用户自行保留 | 文件管理器删除；App 内存档删除、退出或卸载不清理公共副本 | 不包含教务凭据；保存成功后才提示实际路径 |
| 存档分享临时副本 | App 临时目录 `academic-exports` | 随系统缓存清理或卸载 | 系统缓存清理或卸载 | 仅用户主动保存/导出时生成，主动分享时发送 |
