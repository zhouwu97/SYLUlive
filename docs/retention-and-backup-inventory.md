# 保存、备份与日志台账

| 项目 | 位置 | 保存期限 | 删除/覆盖方式 | 当前状态 |
|---|---|---|---|---|
| PostgreSQL 主库 | TODO | TODO | 账号注销、业务删除、备份轮换 | 待核验 |
| PostgreSQL 备份 | TODO | TODO | 备份轮换和到期销毁 | TODO |
| `uploads/` | 服务器/对象存储 | TODO | 内容删除与备份轮换 | 待核验 |
| Caddy/Nginx 日志 | TODO | TODO | 日志轮换 | 待核验 |
| systemd/Go/Python 日志 | TODO | TODO | 日志轮换、敏感字段脱敏 | 待核验 |
| 个人信息请求记录 | PostgreSQL | 按法定/治理义务确定 | 管理员处理与到期归档 | 已有模型，期限 TODO |
| 教务凭证清理任务 | PostgreSQL + Python 服务 | 直到成功或人工处置 | 任务重试、审计结果 | 已有模型 |
