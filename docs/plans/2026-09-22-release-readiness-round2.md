# 1709 发布就绪度：第二轮整改与口径

日期：2026-09-22。承接 [2026-09-21-audit-remediation-plan.md](2026-09-21-audit-remediation-plan.md) 的「证据要求」：
**未运行的全量构建、真实浏览器、PostgreSQL、扩展 Service Worker 或生产告警不得写成已通过。**
本轮只记录代码已经落地的部分，以及在补证据之前不能使用的说法。

## 本轮落地

### R-01 工单账号会话隔离（发布前必修）

写操作的请求级边界此前只有投票、集市、水帖做了：`PublishSessionScope` 会把
`expectedAuthUserId` / `expectedAuthSessionEpoch` 放进 Dio `extra`，认证拦截器在**发请求前**校验一次、
刷新会话后再校验一次。工单的消息、图片上传、重开、确认解决、管理员状态修改、请求补充信息、
负责人修改现已全部走同一个 scope 与 `_writeOptions`。

同时把「账号身份」从 `sessionGeneration` 改回 `accountSessionEpoch`：

- `_pendingMessage` 记的是 `accountId + accountSessionEpoch`，只有同一次账号会话里的同一份请求才复用幂等键。
  旧实现拿 `sessionGeneration` 判身份，而它在**同账号**的资料刷新、头像更新、consent 变化时也会计数，
  于是一次资料刷新会丢掉未确认送达的幂等键，用户再发一次就可能发出重复消息。
- `_handleAuthSessionChanged` 只在「账号 ID 或 accountSessionEpoch」变化时整页重来。
- 旧响应回写 UI 仍按 `sendGeneration` 拦，`sessionGeneration` 不再承担账号身份语义。

覆盖文件：`client/lib/screens/feedback/feedback_detail_screen.dart`（`feedback_create_screen.dart`
与 `client/lib/widgets/image_upload_widget.dart` 在上一轮已接好 scope，本轮复核通过）。

### R-02 CI 红项：`TestOpenAICompatibleProviderDoesNotRetryModelProgress`

旧写法用真实时间窗口断言行为：`firstProgressTimeout=100ms`、外层 context 350ms，再要求
`elapsed >= 250ms`。它表达的其实是两条不变量——

1. 模型进度一出现就必须撤下「首进度看门狗」；
2. 就算看门狗回调已经排队、在进度之后才执行，进度守卫也必须拦住第二次请求。

这两条和调度一赛跑就时红时绿。现在改成可控时序：

- `OpenAICompatibleProvider.afterFunc` 允许测试接管看门狗的构造与触发时机（生产仍是 `time.AfterFunc`）；
- 用例先等「看门狗被撤下」这个**状态**，再手动补发一次迟到的看门狗触发，断言 `attempts == 1`；
- 顺带修了一个真实分类错误：看门狗用 `cancel(context.DeadlineExceeded)` 结束的是 attempt context，
  而错误分类只看业务 context，于是「确实超时了」会被报成 `provider_unavailable`。
  现在 `openAICompatibleStream` 记住本轮 attempt context，分类优先识别它的截止原因。
- 两条姊妹用例的总预算从 3s 提到 30s（它们只作卡死保险，不是断言窗口）。
- 顺带修了两处 `-count=2` 就失败的测试隔离问题（`run_permission_plan_test.go`、`scoped_grant_test.go`
  共用固定名的 shared memory sqlite）。

### R-03 SecurityBlock method-aware

封禁查询挂在鉴权之前，命中就打一次 `security_blocks`。此前只按路径前缀匹配，
于是普通 `GET /api/posts`、`GET /api/search` 每次都先查一遍库——**防攻击层自己成了数据库放大面**。

现在路由登记表增加 `Methods`：内容组只登记 `POST/PUT/PATCH/DELETE`，账号凭据四组不限方法。
请求级唯一策略是 `SensitiveSecurityRouteFor(method, path)`；`SensitiveSecurityRoute(path)`
只回答「这条路径归哪个分组管」，供管理员录入校验与界面展示前缀使用。
`security_block_scopes` 同时下发 `method_policy`，界面不再自己猜。

**没有做**：`content_read_abuse` 一类的独立读取频率限制。读滥用要另做一套限流，
不能塞进来源封禁里和写滥用混在一起。

### R-04 幂等三态与有界缓存

结论不再由状态码独断，handler 可以显式声明：

| 结论 | 表达方式 | 行为 |
| --- | --- | --- |
| 已提交 | `middleware.MarkIdempotentCommitted(c)` | 缓存响应，原键重放同一结果（哪怕不是 2xx） |
| 明确未提交 | `middleware.MarkIdempotentSafeToRetry(c)` | 释放记录，原键可重新执行 |
| 结果未知 | 两者都没标 | 4xx 视为未提交可重试；5xx 保留 `failed` 占位，拒绝原键重放 |

缺省值刻意保守：5xx 可能是「库已经写完、随后的推送失败」，允许原键重放就会在同一次用户操作里
造出第二条业务记录。`classifyIdempotentOutcome` 是这个决策表的唯一实现点。

另外补了响应体上限 `idempotencyMaxResponseSize = 256 KiB`。超限时只落状态码不落正文，
重放返回 `Idempotency-Replay: body-omitted`：写入已经发生，宁可让调用方按状态码处理后重新读一次，
也不能存半截正文让它以为接口就是这个形状，更不能放行同键再执行一遍。
（同键等待的轮询退避在上一轮已从 25ms 改为 100ms 起指数退避、上限 1s。）

### R-05 高危事件主动告警（SEC-06/07 最小闭环）

事件采集、风险聚合、后台处置、临时阻断都已可用，缺的是「管理员不打开安全中心就不会知道」。
新增 `services.SecurityAlertService`：

- 触发条件：`severity ∈ {high, critical}` **且** `models.SecurityEventActionable` **且** `status = active`；
- 去重与冷却：同一 `event_type` 12 分钟内只发一封，另有每小时 12 封的硬额度；
- 投递在后台 goroutine，慢 SMTP 不占用请求路径；判定（冷却/额度）是同步的，
  否则一次攻击会排队发出多封；
- 发送失败只记运行态健康快照 + 限频日志，**绝不回调事件采集**——那会把一次邮件故障放大成写入风暴；
- 邮件正文只带脱敏字段，不含账号、IP 或凭据原文；
- 未配置 `SECURITY_ALERT_EMAILS` 时如实报 `not_configured`，不把「没人被通知」显示成正常。

刻意**不做**：SIEM、升级链路、消息队列。这个体量下「高危 → 去重冷却 → 一封邮件」就是完整答案。

### R-06 学生身份盘点

`legacy_migration` 按兼容策略继续授予准入，但它是否都该继续可信取决于历史数据的真实形态。
盘点过去只有一份需要上生产机器执行的 SQL，容易被拖成「以后再说」。现在：

- `scripts/academic_identity_inventory.sql` 补齐：未登记取值的实际形态、带首尾空白的行数、
  缺验证时间的绑定、按教务提供方拆开的依据分布、(provider_id, student_id) 重复（现行唯一索引下
  只可能是历史脏数据）；
- `models.ReadAcademicIdentityVerificationInventory` 与管理端
  `GET /api/super/academic-identity/verification-inventory`（超级管理员）输出同一批事实，
  **只出计数与已登记/未登记的取值清单，不返回学号、用户 ID 或任何可还原标识**；
- 盘点把「库里实际存了什么」和「判权认什么」分开报：带空白的 `legacy_migration` 不算可信
  （判权精确匹配），必须以未登记脏值的身份暴露出来。

**仍未做**：在生产库上真正跑一次并据此决定是否收紧白名单。这一步需要生产数据访问。

### R-07 发布清单补齐服务端边界

App 只编译客户端源码，但运行时依赖同一仓库的 Server API 契约。此前清单只记 `source_commit`，
于可能出现「Client clean、Server 有未提交配套改动」却仍然产出一个看似可追溯的包。
现在 `client/scripts/build_release.ps1`：

- `server` 工作区不干净时**默认拒绝构建**，需要显式 `-AllowDirtyServer` 才放行；
- 清单记录 `server_expected_commit`（Server 干净时等于 `source_commit`，否则为 null）、
  `server_contract_verified`、`source_tree`（server/web/browser-extension 各自的 clean 与变更条目数）、
  `ci_status`（取自 `RELEASE_CI_STATUS`，未设置时如实记 `unverified`）。
- Web 仍然不阻断 App 打包——它不参与 APK。

### R-08 其它

- 投票分页补上游标：`latest`/`ending` 走 keyset（排序键 + `posts.id` 二级键），
  推荐池用锚点钉住上边界。并发新增因此既不会挤掉下一页，也不会让同一条被翻到两次。
  游标失效时返回 `cursor_stale`，客户端整体替换列表而不是接着往下拼。没有游标的旧客户端仍走 offset。
- 课表写入中止时区分「还没落盘」和「已写进原账号本地课表」：旧文案一律说「请重新操作」，
  会让用户以为刚才的修改丢了、再做一遍，切回原账号才发现多出一份重复规则。
- 删除无人引用的旧 `services.FileService`：它写的是相对路径 `uploads`（不是 `uploadDir`）、
  没有图片内容检测、没有大小上限，且 `GenerateRandomString` 实际是常量串。生产上传链路
  （`UploadHandler` + `UploadProtection` + `ResolveUploadPath` + `FileUploadGrant`）不经过它。

## 口径：现在可以怎么说

| 不建议说 | 目前可以准确说 |
| --- | --- |
| 1709 已通过完整测试 | 1709 已完成签名构建和 SHA/签名校验；本轮整改后 `zhzh` 全量套件本地为绿，发布前仍需在 CI 上复跑并把结果写进清单 |
| 所有跨账号问题已经解决 | 课表、投票、集市、工单的写链路已统一接入账号会话边界（请求发送前拦截 + 响应侧丢弃） |
| 学生身份已经完全可信 | 新身份判权已改为可信白名单；`legacy_migration` 规模与异常形态已有盘点入口，**生产数字尚未取得** |
| 已拥有实时安全预警系统 | 已具备事件采集、风险聚合、后台处置、临时阻断，以及高危/严重事件的邮件主动告警（去重 + 冷却 + 每小时额度） |
| 安全扫描全部通过，因此没有漏洞 | 当前 Go/Python 依赖、Secret Scan 与 CodeQL 扫描通过；Dart/Flutter 与 Android/Gradle 依赖、移动端静态扫描、真机动态行为未覆盖 |
| 投票分页已经完全一致 | `latest`/`ending` 已是 keyset 续页，推荐池已钉住上边界；推荐池内条目被删除仍可能让下标偏移，恢复路径是回到第一页 |
| 管理治理已经完全事务安全 | 预览凭证与旧响应竞态已修复，PostgreSQL 并发写入与行锁顺序仍需实际验证 |
| 成绩问题已彻底解决 | 会话恢复与临时故障分类已修复，真机体验仍需验收 |
| 来源封禁覆盖全部滥用面 | 来源封禁只覆盖登记表内的**写**入口；读取/爬取滥用需要独立频率限制，尚未实现 |

## 仍未宣称完成

- 生产身份盘点的真实数字，以及据此是否收紧 `legacy_migration`；
- 真机关键链路：切号过程中工单/投票/课表操作、成绩首次进入与恢复、工单完整生命周期（关闭→重开→补充→官方回复→确认解决）、上传附件权限；
- PostgreSQL 下的并发合并时序、行锁顺序、真实写入故障与连接池尾延迟；
- 投票推荐池在条目删除下的下标一致性；
- Dart/Flutter 依赖安全、Android/Gradle 依赖、移动端静态安全扫描与真机动态行为；
- 告警邮件的真实送达演练（当前只验证到 SMTP 调用成败与冷却/额度语义，未连真实邮箱跑通）；
- `content_read_abuse` 一类的读取滥用限流；
- [2026-09-21-audit-remediation-plan.md](2026-09-21-audit-remediation-plan.md) 中列出的其余未收口项。
