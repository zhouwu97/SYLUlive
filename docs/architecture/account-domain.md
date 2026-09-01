# Account Domain

状态：PR1 架构契约（迁移中，不能据此宣称生产已经完成四个零）。

本文定义 SYLUlive 账号域与学校个人域的边界。迁移执行以
`SYLUlive-Migration-Execution-Plan-v2.md` 的实际 Base SHA 和发布记录为准；本文件
不把历史代码或一次性兼容路径提升为目标架构。

## 术语

| 术语 | 定义 | 所属边界 |
| --- | --- | --- |
| Account Subject | `users.id`，社区对象、帖子、消息、权限和审计关联的稳定主体 | SYLUlive Account |
| Primary Login Identity | 已验证 Email 对应的有效登录 Identity | SYLUlive Account |
| Account Credential | APP Password 的密码哈希和会话令牌 | SYLUlive Account |
| LocalSchoolProfile | 仅设备本地的学校连接配置和安全存储引用 | Local School |
| School Personal Data | StudentID、学校凭据、Cookie、课表、成绩、考试、学分、二课、体测及可关联派生值 | 学校个人域，禁止进入 Server |

Email 是登录身份，不是 Account Subject。更换 Email 只切换 Identity，不得新建
`users.id`，也不得把 StudentID 重新当作普通登录回退键。

## 目标不变量

1. `users.id` 在整个迁移中保持不变；社区内容、关系、权限和审计引用不迁移主体。
2. 普通 `/api/login` 只规范化 Email、查询有效 Email Identity，再校验 APP Password。
3. StudentID Login 只能存在于单独、可计量、有 Sunset 的迁移路由；它不是普通 Login 的
   fallback。
4. Identity 的唯一性由数据库约束保证。同一类型、同一规范化标识最多一个有效 Identity；
   禁用历史标识不能自动转移给另一个主体。
5. 不创建 `campus_membership_claims`。一次校园准入结果不能永久关联到 Account Subject。
6. Server 不接受、处理或保存学校密码、Cookie、Session、Token，也不把学校个人响应正文
   送入日志、队列、缓存、AI 或备份。

## 账号域允许保存的内容

Server 可以保存完成社区服务所需的 `users.id`、已验证 Email、APP Password Hash、
法律同意、账号状态、权限和必要的安全审计信息。安全审计必须采用最小化、不可回溯的
聚合值；原始学校标识和凭据不属于这些字段。

密码找回、Email 修改和会话失效遵循高风险认证流程：当前有效登录或高可信 Session、
新 Email OTP、事务切换 Identity、递增 `token_version` 并使其他设备失效。OTP 只保存
不可逆摘要，单次消费、十分钟过期、最多五次尝试，且注册检查和找回响应不可枚举。

## 迁移状态

迁移状态只能按顺序推进，并为每次切换生成脱敏对账报告：

```text
S0 LEGACY               users.email / users.student_id 仍是旧读写路径
S1 EXPANDED             创建 Identity 与 Registration Session，旧行为不变
S2 BACKFILLED           仅回填无冲突且已验证的 Email
S3 DUAL_WRITE           事务双写 Identity 与 compatibility mirror
S4 IDENTITY_READ        普通 Login 只读 Email Identity
S5 LEGACY_WRITE_STOPPED 停止 StudentID Identity 写入
S6 RECONCILED           Identity 与 mirror 差异为零
S7 LEGACY_REMOVED       PR12 硬删除旧 Identity 与旧字段
```

S1 至 S3 可在不删除新表数据的前提下回退。进入 S4 后只能前滚修复 Email 路径，不能
把普通 Login 偷换回 StudentID 查询。`registration_sessions` 只保存状态机元数据，
最长三十分钟；不保存 StudentID、学校凭据、Cookie、学校正文或可反推账号的错误文本。

## 依赖方向

```text
Account Domain  -> 账号、权限、社区关系、法律同意
Local School    -> 设备端学校连接、解析器、本地缓存
School Public   -> 无个人凭据的公开资讯读取

Account Domain  -X-> 学校个人运行时
Server AI       -X-> LocalSchoolProfile / 学校个人运行时
Device Job      -X-> Server School Authority
Registration    -X-> 普通学业运行时
```

跨边界需求必须先建立独立接口和数据契约，并经过 Security Reviewer；禁止通过配置开关、
重试器或“暂时兼容”偷偷恢复 Server 学校权限。

## 验收证据

每个实现 PR 必须记录 Base Branch、Base SHA、Schema/Production Config 快照时间、扫描
命令及原始结果、迁移前滚/回退、观察窗口、Owner 和 Release Commander。报告只能保存
脱敏聚合，不得把 Email、StudentID、Cookie、Token 或学校密码写进 Git、Issue、CI
Artifact 或普通日志。
