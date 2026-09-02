# School Data Boundary

状态：PR1 安全契约。本文定义数据类别和处理边界；“零”是验收目标，不代表当前仓库
已经完成后续 PR 的清理。

## 四个零

### Zero Credential

Server 的 API、日志、Trace、Queue、DB、Cache、Backup 和运行时入口均不接收、处理或
保存 School Password、Cookie、Session、Token。学校凭据只在设备本地安全存储和一次
明确触发的请求生命周期内存在。

### Zero Personal School Data

Server 不保存或处理可关联到自然人或 Account Subject 的 StudentID、校园准入结果、
课表、课程、成绩、考试、学分、学业状态、二课、体测及其派生摘要。`users.id`、已验证
Email 和 APP Password Hash 属于账号域，不因名字相近而归入学校个人数据。

### Zero School Authority

Server 不能直接访问学校个人系统，也不能指令设备访问、刷新、读取或回传学校个人数据。
应用代码检查不是唯一网络边界；必须同时有 egress proxy、容器网络策略或主机防火墙的
可复核证据。

### Zero Hidden Fallback

Release 构建中不存在 RemoteAcademicGateway、Server Academic 路由调用、School Device
Tool 或把 Local failure 切回 Server 的配置/代码路径。字符串、默认开关和重试分支也在
扫描范围内，不能用“默认关闭”替代删除。

## 数据流规则

| 流程 | Server | 设备 | 结果 |
| --- | --- | --- | --- |
| 账号注册/登录 | Email、APP Password Hash、同意和会话 | 不需要学校数据 | 允许 |
| 学校个人查询 | 不接收学校凭据或正文 | `SchoolPersonalClient` + LocalSchoolProfile | 仅本地 |
| 学校公开资讯 | 只可读取无个人登录的公开来源 | 可有本地缓存 | 不得混入个人 Cookie |
| 用户授权摘要上传 | 仅接收最小结构化摘要，且需明确同意 | 由设备生成 | 可撤销、可删除 |
| 校园准入 | 迁移期可能短暂存在 | 一次性触发 | 不写入 User/Profile/AI，不建 `campus_membership_claims` |

禁止把原始 HTML、学校响应错误、验证码、Cookie Header、StudentID 或可逆哈希放入
日志、异常、指标标签、队列消息、AI Prompt、数据库备份和 CI Artifact。仅允许保留
无法关联到用户、StudentID、Email、IP、设备或请求的聚合计数。

## TLS 与发布物

生产 Python/Go 源码命中 `verify=False`、`verify = False` 或 `CERT_NONE` 即阻断。测试
或诊断探针如需坏证书模拟，必须放在不进入生产发布物的路径；`.dockerignore`、多阶段
Dockerfile 或等价 Release Manifest 必须独立证明排除结果。不得通过永久关键词
allowlist 让命中“变绿”。

Flutter 临时 SPKI 兼容回调必须精确限定到批准文件，写明 Owner、原因、当前/备用指纹
和 PR6 删除边界。PR6 只能删除该策略，不能只延长日期或扩大 Host 范围。

## 证据和保留

每次发布保存：扫描器 JSON、源码和发布物摘要、数据库读写计数、egress 观察窗口、负向
测试结果、停止/回退负责人和 Commit SHA。原始明细只允许进入带访问控制、审计和自动
过期的临时工作区；处理完成后删除并记录删除证据。Live Zero 与 Historical Zero 分开
判定，备份尚未到期时必须写明 `Historical Zero - Pending Retention Expiry`。
