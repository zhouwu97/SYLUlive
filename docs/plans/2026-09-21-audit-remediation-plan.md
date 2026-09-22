# SYLUlive 审核整改实施清单

基于 `SYLUlive_近一周功能审核与详细修改计划_2026-09-21.md` 整理。本文是执行清单，不把隔离探针结果当作全量测试通过证据。

## 已冻结的处置决策

- `browser-extension/src/school.ts` 中的体测签名 key 属于公开客户端常量：只在 Gitleaks 中按“精确字符串 + 精确文件路径” allowlist，禁止泛化忽略；不把它改名伪装成服务端密钥。
- 体测 Provider 默认关闭。用户必须在助手页主动开启，并看到 HTTP 明文传输、MD5 值可重放的风险确认；未开启时身份读取、登录和资料查询均拒绝。该开关不上传服务端，也不保存学校密码。
- 官方表情包 `version` 使用人工/发布流程递增的 catalog 发布序号；`manifest_sha256`/`content_sha256` 只承担内容不可变校验，不参与推导序号。

## PR 顺序与可执行任务

### PR-00：发布门禁与扫描证据

- [ ] 新增精确 Gitleaks 配置，并让 security workflow 显式使用配置。
- [ ] 记录当前工作区已有修改，不将无关文件带入发布 diff。
- [ ] 运行 `gofmt`、server 定向测试、secret scan；格式或扫描失败时保留失败证据，不宣称发布验证完成。
- [ ] 核对官方表情目录的人工版本号、内容摘要和回滚说明。

### PR-01：投票可见性与规则门禁

- [ ] 把投票详情、按 ID 回读、列表补全和投票写入统一到公开状态白名单。
- [ ] 治理隐藏、删除和未知帖子状态默认不可读、不可投票；事务内复核当前状态。
- [ ] 仅给投票发布和编辑挂载社区规则确认门禁，不误伤投票、关闭和删除等其他操作。
- [ ] 增加隐藏投票详情/写入及未确认规则的 HTTP 契约测试。

### PR-02：身份依据分级

- [ ] 将本机连接、学号声明、可信学校认证拆成独立字段和判权语义。
- [ ] 自报学号不得返回可信 `verified`，不得永久占用全局唯一学号绑定。
- [ ] 盘点 `StudentVerifiedAt`、绑定 `verified_at` 和 `verification_method` 的所有消费方，迁移采用双读、统计、备份、试运行。
- [ ] 提供错误绑定、冻结旧路由和网络超时后的恢复入口。

### PR-03：Web 会话世代与 401 重放隔离

- [ ] 建立认证会话 epoch，请求记录起始 epoch 和 user id。
- [ ] refresh 前、完成后、写请求重放前校验 epoch；切号/退出时使 epoch 失效并中止在途写请求。
- [ ] 非幂等写请求禁止跨账号自动重放；必要时改用服务端幂等键。
- [ ] 覆盖延迟 401、双标签切号、上传中退出和刷新失败循环测试。

### PR-04：扩展撤权状态机

- [ ] 为 origin + provider 建立递增 generation/revocation token。
- [ ] `confirm`、`persistence`、`cache`、`window`、`reminders`、`query` 在异步提交前复核同一 generation。
- [ ] disconnect 先撤销世代，再取消请求、清理连接和提醒；旧请求不得恢复新连接。
- [ ] 增加 confirm 卡住后 disconnect、旧身份失败覆盖新连接等扩展集成测试。

### PR-05～PR-10：后续链路

- PR-05 成绩静默恢复不弹教务登录框。
- PR-06 表情安装历史、回滚指针和崩溃恢复。
- PR-07 教师/课程合并预览快照、错误传播和事务验证。
- PR-08 安全事件超时、`/health` 一致性、封禁范围和真实告警演练。
- PR-09 投票分页契约及 Web 工单私有附件渲染/操作恢复。
- PR-10 补充 18 个关联场景、发布物一致性和最终签字。

## 本轮实施边界与当前进度

已落地或已开始落地：

- PR-00：精确 Gitleaks allowlist、workflow 显式配置；官方表情包的人工发布序号/内容摘要改动保留并已补定向测试。
- PR-01：投票公共状态白名单、隐藏状态读写拒绝、ending total/推荐候选池稳定顺序、投票发布/编辑规则门禁。
- PR-02（第一步）：本机身份声明不再写入可信绑定表；响应明确返回 `verified=false` 与 `assurance_level=local_declaration`；可信判权和已有下游读取排除 `local_academic_login`。
- PR-03（第一步）：Web 写请求不再在 401 后自动重放；认证世代变化会中止在途请求，读请求刷新绑定发起时世代。
- PR-04（第一步）：扩展连接 key 增加串行提交边界，`confirm`、缓存偏好和查询缓存写入在异步提交前复核连接 epoch。
- PR-05（第一步）：成绩页用 `GradeRefreshOrigin` 贯穿全部刷新入口，「能否突破新鲜期」「能否弹教务登录框」「能否用减少结果覆盖基线」三项权限各自独立；`automatic`/`resume` 只做无感恢复，需要人工输入时保留旧结果并显示页面内非阻塞提示（`GradeSessionNotice`），只有 `initial`/`manual` 可以弹交互登录框。审计验收 GRADE-01、GRADE-02 已加 widget 反例测试，GRADE-04/05 由既有决策表与减少确认测试覆盖。
- PR-06（第一步）：表情包索引新增 `previous` 历史指针（`EmojiPackVersionRef`），`store.commit` 只在活动版本真的换人、且换入换出双方都是成功安装时推进它；回滚改为读取该指针并先完整校验上一版目录（Manifest 身份 + 每个资源哈希）再原子切换，老索引没有历史指针时直接提示重新下载而不猜版本顺序；版本目录清理也只跟着「当前 + 上一版」两个指针，不再按版本数值或哈希大小判定先后。审计反例（先装 9001 再装 1001）与 EMO-01/02/03 已落成定向测试。
- PR-07（第一步）：合并预览凭证改为 `数据快照摘要.操作意图摘要` 两段式（`gov-snapshot-v2`）。意图摘要由规范化后的 `MergeInput`/`CourseMergeInput`（keeper/loser 角色、最终名称、别名登记策略、跨课程学科决策、别名目标）参与哈希，数据摘要逐条记录每个实体的 keeper/loser 角色标签，因此「A 并入 B」的旧凭证不能用于反向的「B 并入 A」，别名改指向、学科决策改变、最终名称改变都会使凭证失效；同一意图内 loser 顺序、教师配对顺序、多余的 `0` 不再使凭证失效（执行侧统一走规范化后的入参，幂等重试仍然可用）。事务内复核同时比对两段，分别返回「数据状态已发生变更」与「操作方案与预览时不一致」，沿用 `GOVERNANCE_SNAPSHOT_STALE`/409。快照读取全部改经 `govSnapshotReader`，按 stage 标注错误并一律上抛（预览失败不再返回半截凭证；事务内读取失败回滚整个合并），失败与「查询结果为空」在测试里可区分。凭证仍只是预览一致性令牌，不是授权：服务层以 `adminID==0` 拒绝执行。GOV-01～09 落成 `teacher_governance_intent_test.go` 与 `teacher_governance_snapshot_test.go`（含读写故障注入、空/失败区分、幂等重试不重复审计）。
- PR-08（第一步）：安全事件写入的内部预算改为**上限**而不是默认值——`RecordContext` 之前只在父 context 没有 deadline 时补 2s，带 30s deadline 的调用链原样保留 30s；现在无条件派生 `WithTimeout(parent, 2s)`，父更早则按父结束。context 贯穿到聚合计数（新增 `CountDistinctTargetsForEventsContext`）与安全中心总览的 12 条读查询（整次共享 `SecurityOverviewBudget=5s`），9 处 handler 写入点迁到带 context 入口，写入侧用 `WithoutCancel` 派生以免客户端断开抹掉撞库/令牌复用/可疑改密这类信号；写失败新增限频降级日志（每分钟一条，只走内存判断、不经故障写入器递归）。A11：层状态判定（`EventCollectionState`/`BlockLookupState`）收到服务层，`/health` 与安全中心总览共用一份结论，事件写入 degraded/unavailable 时探针一并 503，启动后未探测只报 `unknown` 不判失败；公共 `/health` 不再输出 `trusted_proxy_cidrs` 与归因生效时间。A12：中间件路由登记表（登录注册/验证码/改密换绑/会话刷新/内容写入五组）成为唯一来源，`SensitiveSecurityRoute` 与管理员 `account` 范围都由它派生（按用户决策补齐到凭据全组，内容/检索仍明确排除），总览新增 `security_block_scopes` 描述实际前缀与不包含项，Flutter 页面删掉手抄清单改渲染服务端数据。SEC-01～05、09～11 落成 `security_event_deadline_test.go`、`security_event_context_test.go`、`security_overview_context_test.go`、`security_public_health_test.go`、`security_block_scope_registry_test.go`、`security_route_registry_test.go` 与客户端范围说明用例；关键断言做了 RED→GREEN 与变异检查（删登记项、删日志调用、放宽预算均被指定测试抓住）。
- PR-09（第一步，A13）：投票列表分页契约自洽。`PollListResult` 显式区分 `total`（这一次请求翻得到的候选数）、`matched_total`（全站匹配数）、`pool_size`（推荐候选池上界，非推荐排序为 0）与 `has_more`（服务端结论：offset 路径多取一行探测，推荐路径按窗口位置判断）；推荐池 `pollRecommendPoolSize=500` 先按 `posts.created_at DESC, posts.id DESC` 装载再内存重排，`total` 只统计池内条数，不再出现「总数 530、翻到第 26 页永远空白」；`latest`/`ending` 同样补上 id 二级键，同分数据翻页不再抖动。Flutter 侧优先采用 `has_more`，只有旧响应缺该字段才退回按长度猜。POL-07～10 落成 `poll_list_contract_test.go`（服务层：530 条候选走满 25 页、陈旧页可恢复、隐藏投票跨页不泄漏）与 `poll_pagination_contract_test.go`（HTTP 层字段齐全），客户端由 `poll_provider_test.dart`、`poll_list_pagination_test.dart` 钉住；RED→GREEN 已记录，5 项变异检查中 4 项被指定测试抓住，剩下 1 项（把 offset 探测换成 `page*limit<matched`）只由代码不变量支撑。
- PR-09（第二步，A14）：Web 工单私有附件链路恢复。新增 `web/src/attachments.tsx`：附件编号只从 `file_id`/`file.id`/`id` 取，地址唯一出口是带鉴权的 `/api/feedback/attachments/:file_id`（以字符串形式流下来的 `/uploads` 直链在这里被挡成空地址）；`requestBlob` 复用与 JSON 请求相同的认证世代链路（401 刷新后重放、切号中止在途读取），失败按状态码分成「登录已失效」「无权查看或文件已删除」两类不可恢复状态与可重试状态；初始区优先 `initial_submission.attachments`，回退 `ticket.attachments` 时扣掉后续消息已挂的编号，避免把管理员后来发的图重复显示成初始提交的一部分；消息来源按服务端枚举映射（系统事件/初始提交/官方回复/请求补充信息/内部备注/用户补充），不再把非 admin 一律标成用户补充。上传前按服务端实际口径提示数量/类型/大小（jpg/png/gif、单张 10 MiB、最多 6 张，服务端仍是最终裁决），`uploadIDs` 用 `WeakMap<File, number>` 记住已传编号，业务提交失败后原样重试不再重传，`Form` 的 busy 锁避免重复发送消息；已关闭工单的用户侧回复表单换成「需要重开」说明而不是注定 409 的发送按钮；管理员「返回列表」改为带回筛选参数的 `/admin?tab=feedback`（管理端工单列表不是独立路由）。TKT-01～05 落成 `attachments.test.ts`（13 例）、`api.test.ts` 新增 4 例二进制读取用例，以及 Playwright `feedback-attachments.spec.ts`（真实浏览器 4 例：渲染去重与来源标签、灯箱放大、关闭态解释与重开入口、返回地址筛选）；变异检查覆盖初始区去重、标签映射、按文件名剔除附件、缺失 Accept 头、`/uploads` 泄漏各一处，均被指定测试抓住。过期未引用临时文件的清理仍由既有 `temporary_file_janitor` 承担，本轮只确认该实现存在，未复跑回收流程。
- 顺带修复：课表周次测试的两类时区/夏令时假设（`_seedVault` 把开学周写成带时分的本地瞬时、`_mondayOf` 与整周偏移用绝对时长），改为与生产 `writeSemesterStart` 一致的日历日形态；这是本分支既有的 3 例失败，与审计条目无关。

仍未宣称完成：PR-02 的历史数据统计/数据库迁移与所有身份消费方盘点、PR-03 的真实 Cookie/E2E、PR-04 的真实 MV3 Service Worker 集成测试、PR-05 的 GRADE-03（成绩/GPA/学分并发只触发一个登录流程，现仅由「同进程恢复」测试断言页面上只有一个登录框间接覆盖）与 GRADE-06（真机快速滚动、返回恢复、键盘手感）、PR-06 的 EMO-04（暂停/退出账号后不得悄悄完成对错误上下文的索引切换，需要真机与安装器集成测试）与老索引的批量迁移统计、PR-07 的 HTTP 层角色中间件测试（GOV-05 目前只在服务层断言 `adminID==0` 被拒）、PostgreSQL 行锁顺序与并发合并时序（本轮故障注入测试跑在内存 sqlite 上）、快照步骤以外写失败的通用回滚断言、以及 Flutter 工作台「预览失败后不得沿用旧凭证」的交互测试（A09 第 3 条：现有代码在预览失败时保留旧选中项并关闭预览面板，尚无 widget 测试钉住）、PR-08 的 SEC-06/07 外部告警送达与冷却/升级闭环（本仓库没有可用外部渠道的证据，本轮只做到「探针与看板一致降级 + 限频日志」，管理页关闭后无人得知这半仍然成立）、PostgreSQL 连接池在慢查询下的尾延迟与真实写入故障（预算测试用 gORM 回调替身模拟悬挂写入，跑在内存 sqlite）、`email_verification_service` 内部 5 处仍在无 context 的后台路径上写事件、SEC-13 越权面只有既有路由注册（superAdmin 组）作依据而无 HTTP 层契约测试、SEC-12 共享出口下的真实误伤评估与撤销时效、PR-09 剩余的 PostgreSQL 分页行为（同分二级键与候选池截断只在内存 sqlite 上验证过，真实库的排序稳定性未复现）、跨页游标/快照（并发新增仍可能让某一页少条，恢复路径是回到第 1 页重拉）、工单附件的服务端真实链路（浏览器用例用 route mock，没有打到真实 `ServeAttachment`，私有化与逐引用鉴权只由既有 Go 测试支撑）、TKT-06 全链路（关闭→重开→补充→官方回复→确认解决，本轮只断言了关闭态的解释与重开入口，未跑完整往返）、工单缩略图在真机窄屏与深色主题下的观感，以及 PR-10。它们必须在对应证据补齐后单独收口，不能把本轮定向测试当作全量验收。

## 证据要求

每个 PR 必须记录：复现前行为、变更文件、定向测试命令及实际结果、失败注入或并发时序、旧客户端/数据影响和回退方案。未运行的全量构建、真实浏览器、PostgreSQL、扩展 Service Worker 或生产告警不得写成已通过。
