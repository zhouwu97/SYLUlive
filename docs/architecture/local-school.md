# Local School Architecture

状态：PR1 目标架构契约。Local School 尚未等同于发布完成；任何现存 Server 学校路由
都必须按迁移计划单独退役并提供 410/调用次数证据。

## LocalSchoolProfile

`LocalSchoolProfile` 是设备独占的配置与凭据容器，不是 Server User Profile，也不是
`users.id` 的附属学校档案。允许的本地内容包括：

- 学校连接主机、端口、协议和 parser 版本；
- 用户明确输入的 StudentID 或学校账号标识；
- 由系统安全存储保护的学校密码、Cookie 和短期 Session；
- 最近一次本地同步的结构化缓存及其时间、完整性和覆盖范围。

上述内容可以在设备上存在，但禁止同步到 App API、日志、崩溃报告、分析事件、远程
队列、AI Prompt、备份或云端配置。卸载、用户删除本地学校配置或账号切换时必须清理
对应安全存储和缓存；缓存信封必须绑定当前 Account Subject 的不可逆本地命名空间，
不能跨账号复用。

## 三类客户端隔离

| 客户端 | 允许访问 | 禁止携带 |
| --- | --- | --- |
| `AppApiClient` | SYLUlive 账号、社区和已授权最小快照 | 学校 Cookie、学校密码、学校个人 Header |
| `SchoolPersonalClient` | 设备本地学校个人系统 | App JWT、社区 Cookie、远程上传凭据 |
| `SchoolPublicClient` | 已批准的公开学校资讯 | 任何学校个人 Cookie 或 Credential |

三者使用独立的 HTTP Client、CookieJar、Host Allowlist、超时和日志脱敏策略。重定向
逐跳重新校验主机和端口；不允许用一个共享 Session 或“通用请求客户端”跨边界传递
Cookie。

## 本地失败语义

本地学校请求失败、证书错误、解析失败、过期或超时，只能返回可分类的本地失败状态。
客户端可以展示已有的本地缓存或要求用户再次触发；不得把失败自动切回 RemoteAcademicGateway、
Go `/api/edu/*`、Python 学校路由、School Device Tool 或其他 Server 代理。发布构建中
这些 fallback 的代码、配置、字符串和 feature flag 必须为零。

## 解析与同步

解析器必须 fail-closed：字段缺失、来源版本未知、响应超出上限或校验失败时，不得把
猜测结果当作课程、成绩、考试、学分、二课或体测事实。每个数据集记录本地来源、抓取
时间、覆盖学期和完整性状态；不记录原始页面正文。

同步只由用户在设备上明确触发。学校凭据不得作为后台自动任务、推送任务或 AI 工具
调用的隐式输入。上传结构化摘要（若产品和法律同意允许）必须是单独、最小化、可撤销
的授权；上传失败不能删除或改变本地缓存，也不能触发 Server 重新抓取。

## 生命周期与删除

LocalSchoolProfile 的清理至少覆盖：登出、账号切换、撤销学校授权、应用卸载和用户
删除请求。清理操作应返回可审计的聚合结果，不写出标识或凭据。Server 侧只保留真正
属于账号域的授权状态，不复制校园准入结果，不创建 `campus_membership_claims`。

## 必测负向场景

```text
School cookie -> AppApiClient = 0
App JWT       -> SchoolPersonalClient = 0
本地 TLS / parser 失败 -> Server fallback = 0
账号 A 缓存 -> 账号 B = 0
后台任务无用户触发 -> 学校个人请求 = 0
```

这些测试必须在真实发布构建或等价 Release Artifact 上执行，不能只在探针目录或 Debug
配置中证明。
