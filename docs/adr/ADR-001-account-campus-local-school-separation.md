# ADR-001：账号、校园准入与本地学校能力分离

- 状态：Accepted for PR1（后续 PR 必须遵守；完成状态仍以发布证据为准）
- 日期：2026-08-31
- 决策 Owner：Migration Owner / Security Reviewer（由发布记录填写实际姓名）
- 关联计划：`SYLUlive-Migration-Execution-Plan-v2.md` PR0、PR1

## 背景

历史实现把社区账号、学校登录凭据、校园准入和学业抓取串在同一条 Server 链路上。
这种设计让学校密码、Cookie、StudentID 和个人学业数据可以进入 API、数据库、日志或
远程任务，也使本地失败可能悄悄回退到 Server School Authority。目标架构要求 Email
成为正式登录 Identity，学校能力只在用户设备本地运行。

## 决策

1. `users.id` 是稳定的 Account Subject；verified Email 是 Primary Login Identity；
   APP Password 是 Account Credential。Email 不是永久主体，换 Email 不新建 User。
2. `LocalSchoolProfile` 只存在设备本地安全存储和本地缓存命名空间。学校个人凭据、
   StudentID、Cookie、Session 和学校响应正文不得进入 Server。
3. 账号、学校个人、学校公开资讯使用不同客户端、CookieJar、Host Allowlist 和日志
   策略。LocalSchool 失败不得 fallback 到 RemoteAcademicGateway 或 Server Academic。
4. 不创建 `campus_membership_claims`；校园准入只允许在迁移窗口作为一次性状态机元数据
   存在，过期/消费后按 TTL 清理，不能关联回 `user.id`。
5. Server 默认不具备学校个人访问权。任何迁移兼容路由必须独立、可计量、带 Sunset，
   最终返回 410 并删除实现、配置、密钥和 egress。
6. 生产 TLS 使用系统标准验证；坏证书探针只能存在于不进入发布物的路径，并由独立
   Release Artifact 检查证明排除。

## 四个零的验收含义

```text
Zero Credential           Server 不接收/处理/保存 School Password、Cookie、Session、Token
Zero Personal School Data Server 不保存可关联个人的学校数据及派生摘要
Zero School Authority     Server 不能访问学校个人系统或远程指令设备读取
Zero Hidden Fallback      Release 不含 Remote Academic / Server fallback 路径
```

这些是可验证的发布 Gate，不是当前 PR1 合并即自动成立的声明。PR0/PR1 只建立 TLS、
源码扫描、镜像边界和契约；PR4 以后逐步迁移和删除，PR13 才能作最终结论。

## 影响与取舍

- 用户需要在设备上重新输入或更新学校凭据；Server 学校查询可能在迁移期被暂时关闭。
- 本地失败时功能可能不可用，但不会扩大 Server 权限或上传个人数据。
- 账号域获得更清晰的删除、审计和 Email 变更边界；学校数据清理和备份保留成本下降。
- 旧客户端兼容需要显式 Sunset、最低版本阻断和独立指标，不能用长期 fallback 换取可用性。

## 迁移与回退

按 S0→S7 状态机分阶段执行。S1 至 S3 可关闭新读路径回退，保留已确认的新表数据；
进入 S4 后不允许把普通 Login 改回 StudentID fallback。旧字段在 S7 前不得 DROP，
`registration_sessions` 按创建时 `policy_version` 完成或过期，不能在策略切换时静默
提升状态。每一阶段必须附脱敏对账、读写计数、扫描、负向测试和停止/前滚责任人。

## 不选的方案

| 方案 | 不采用原因 |
| --- | --- |
| Server 长期保存学校凭据并代抓取 | 违反四个零，扩大凭据泄露和学校权限风险 |
| 用 `campus_membership_claims` 记录准入结果 | 把学校事实永久关联到 `user.id`，违反 Zero Personal School Data |
| 普通 Login 未命中 Email 时查询 StudentID | 隐藏 fallback，无法完成 Email Identity 读切换 |
| 只在应用代码中做 egress Allowlist | 代码绕过或配置误开时仍可直连，缺少网络层约束 |
| 对 `verify=False` 建永久 allowlist | 会把危险命中变成静默债务，无法证明生产安全 |

## 必须保留的证据

每个 PR/Release Record 记录 BaseBranch、BaseSHA、Schema/Production Config 快照时间、
变更文件、测试原始结果、数据库前滚/回退、灰度指标、TLS/egress 扫描、发布物摘要和
六类角色签字。原始 Email、StudentID、Cookie、Token、密码和可回溯明细不得进入 Git、
Issue、PR、CI Artifact 或普通对象存储。
