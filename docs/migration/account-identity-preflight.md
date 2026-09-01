# Account Identity Preflight（脱敏聚合报告模板）

> 本文件是 PR2 生产预检的提交模板，不代表尚未执行的统计结果。运行只读脚本后，
> 仅将聚合数字填入本文件；原始 Email、StudentID、IP、Cookie、Token、学校密码和
> 可回溯冲突明细不得进入 Git、Issue、PR、CI Artifact 或普通日志。

## 证据元数据

| 字段 | 值 |
| --- | --- |
| BaseBranch | `diaofenyuan` |
| BaseSHA | `<运行时 git rev-parse HEAD>` |
| SchemaSnapshotAt（Asia/Shanghai） | `<YYYY-MM-DDTHH:MM:SS+08:00>` |
| 查询脚本 Commit SHA | `<包含脚本的 Commit SHA>` |
| 查询脚本 SHA-256 | `<identity_preflight.py SHA-256>` |
| 运行命令 | `<不包含 DSN、令牌或个人标识>` |
| 报告版本 | `identity-preflight-v1` |
| 只读事务 | `true` |

## 统计口径

脚本对 `users` 表执行聚合查询。缺少历史字段时，指标必须标记为跳过，不能用猜测值
替代。邮箱冲突按规范化前的 `LOWER(email)` 分组；正式回填仍须使用服务端的完整
Email 规范化（首尾 ASCII 空白、控制字符、单个 `@`、IDNA 域名和项目统一小写规则）。
`users.email` 在 S3 双写和 S6 对账时必须已经保存为同一规范化结果；仅大小写相同而
规范化不同的镜像也应计入差异并先修复。

## 聚合指标

| 指标 | 数量 | 统计备注 |
| --- | ---: | --- |
| 总用户数 | `<count>` | `users` 总行数 |
| email 为空 | `<count>` | 空字符串或 NULL |
| email 未验证 | `<count>` | 非空且 `email_verified_at IS NULL` |
| LOWER(email) 重复组 | `<count>` | 只保存重复组数量 |
| QQ compatibility email | `<count>` | `qq` 与 `email` 的兼容匹配数量 |
| 只有 StudentID | `<count>` | 非空 StudentID 且无 Email |
| StudentID 重复组 | `<count>` | 只保存重复组数量 |
| active 用户 | `<count>` | 按账号状态 |
| cancelled 用户 | `<count>` | 按账号状态或注销时间 |
| 管理员账号 | `<count>` | `admin` / `super_admin` |
| registration_cleanup_pending | `<count>` | 注册残缺或教务清理待处理 |

## 用户分类与处理策略

| 分类 | 数量 | 自动迁移 | 需用户操作 | 人工审核 | 处理策略 |
| --- | ---: | --- | --- | --- | --- |
| A 已验证真实邮箱 | `<count>` | 是 | 否 | 否 | 仅回填已验证且无冲突的规范化 Email Identity |
| B QQ compatibility email | `<count>` | 仅冲突为零时 | 否 | 视冲突而定 | 保留 `users.id`，不把 QQ 重新当作新账号主体 |
| C 有邮箱但未验证 | `<count>` | 否 | 是 | 否 | 发送 Email 验证；不得创建假邮箱 |
| D 无邮箱 | `<count>` | 否 | 是 | 否 | 通过不可枚举流程补充并验证 Email |
| E 邮箱冲突 | `<count>` | 否 | 否 | 是 | 隔离到受访问控制、审计和自动过期的临时工作区 |
| F 历史注册残缺 | `<count>` | 否 | 否 | 是 | 按账号状态和删除策略人工处置 |

自动迁移只允许写入确认属于同一 `user.id` 的有效 Email Identity；禁止覆盖其他主体、
批量生成占位邮箱或把 StudentID 写入普通 Login Identity。

## 重复运行差异

| 指标 | 本次 | 上次 | 差异（本次-上次） |
| --- | ---: | ---: | ---: |
| 总用户数 | `<count>` | `<count>` | `<delta>` |
| email 为空 | `<count>` | `<count>` | `<delta>` |
| email 未验证 | `<count>` | `<count>` | `<delta>` |
| LOWER(email) 重复组 | `<count>` | `<count>` | `<delta>` |
| QQ compatibility email | `<count>` | `<count>` | `<delta>` |
| 只有 StudentID | `<count>` | `<count>` | `<delta>` |
| StudentID 重复组 | `<count>` | `<count>` | `<delta>` |
| active / cancelled | `<count>` | `<count>` | `<delta>` |
| 管理员账号 | `<count>` | `<count>` | `<delta>` |
| registration_cleanup_pending | `<count>` | `<count>` | `<delta>` |

差异只表示聚合数字变化。若需处理冲突明细，应在受控临时工作区完成，并记录访问、
处理人、删除时间和删除证据；本报告不引用该工作区中的原始值。

## 静态依赖盘点

运行 `scripts/migration/identity_dependency_inventory.py`，并将其聚合结果作为 PR3
expand/backfill 和 PR12 drop 的共同输入。结果至少按以下类别记录文件命中数：

| 类别 | 含义 |
| --- | --- |
| `read` | 查询、读取模型字段或请求参数 |
| `write` | INSERT/UPDATE/DELETE、赋值或写入请求 |
| `response_output` | API/序列化/日志/导出/界面响应输出 |
| `index_constraint` | SQL 索引、唯一性、约束或迁移定义 |
| `test_fixture` | 测试、Fixture、Mock、探针样例 |

盘点范围覆盖 `server/`、`python-edu-service/` 和 `client/` 的源码、SQL、配置与测试，
并检查：`users.student_id`、`users.student_verified_at`、`users.email`、
`users.email_verified_at`、`users.qq`、`Edu*`、管理员/搜索/帖子/消息/隐私导出/注销中
的 StudentID、旧 Auth API 以及客户端请求字段。脚本只输出路径、依赖类别和命中计数，
不输出命中行、原始标识或字段值。

## 验收签字

| 角色 | 姓名 | 时间（Asia/Shanghai） | 结论 |
| --- | --- | --- | --- |
| Migration Owner | `<name>` | `<time>` | `<pass/hold>` |
| Backend Owner | `<name>` | `<time>` | `<pass/hold>` |
| DBA / Data Owner | `<name>` | `<time>` | `<pass/hold>` |
| Security Reviewer | `<name>` | `<time>` | `<pass/hold>` |

在冲突规模、依赖清单、脚本摘要和只读快照均复核前，不得执行 PR3 backfill，也不得
宣称 Email Identity 已成为唯一登录真源。
