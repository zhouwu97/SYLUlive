# 治理闭环收口：图片鉴权、通知可靠性与管理端审核依据

日期：2026-09-16
范围：`c4088e1c` 之后的收口改造，只修 4 个已识别缺陷，不扩功能。

## 1. 背景

`c4088e1c` 之后，治理主链路（举报成立 → `moderated_hidden` → 作者通知 → 作者可读可改
→ 提交整改 → 管理员复审 → 恢复/驳回 → 申诉）结构已经成立。评审指出 4 个未闭环点：

| 优先级 | 问题 | 后果 |
| --- | --- | --- |
| P1 | 治理帖图片在客户端仍按 public 加载 | 正文能看、图片全裂 |
| P1 | 整改/申诉结果站内通知写在事务外且忽略错误 | 帖子已恢复但作者永远收不到通知 |
| P2 | 申诉结案给作者发两条并列通知 | 「申诉已通过」+「申诉结案结果」重复 |
| P2 | 管理端整改卡缺少「当初为什么被处理」 | 只能「看着挺正常就点通过」 |
| P2 | 过期待办 409 只弹通用错误 | 管理员以为系统坏了，反复点同一个按钮 |

## 2. 修复一：治理帖图片改为鉴权私有加载

### 服务端既有事实（未改动，只做确认）

- 治理隐藏时 `services.ReconcileFilePublicAccess` 会把没有其他公开引用的文件从
  `public` 降级为 `private`；帖子图片只有 `normal / sold / closed` 算公开引用
  （`internal/services/file_reference_service.go`）。
- `/uploads/*filepath` → `UploadHandler.ServePublic`，命中私有文件时走
  `isAuthorizedForPrivateFile`：`admin` / `super_admin`，或 `file.UploaderID == user_id`
  放行，其余 404，并回 `Cache-Control: private, no-store`。

结论：**不需要**为了图片能显示而重新开放公开 URL，客户端缺的只是鉴权加载路径。

### 客户端改动

新增 `client/lib/utils/governed_post_image_cache.dart`：

```text
GovernedPostImageCache
  - 独立 CacheManager（governed_post_image_cache_<accountId>）
  - cacheKey 规范：governed_post:<accountId>:<url>
  - 凭证绝不进入 cacheKey（cacheKey 会落到磁盘文件名）
  - 注册 AccountSessionCleanupCoordinator，登出/换号清空
```

新增 `client/lib/utils/post_media_access.dart`：

```dart
enum PostMediaAccessMode { public, authorized }

class PostMediaAccess {
  const PostMediaAccess.public();
  const PostMediaAccess.authorized({required String token, int? accountId});
}
```

用值对象而不是散落传 `accessMode + token + accountId`：`authorized` 缺 token 这种
组合在类型层面构造不出来 —— 它正是「正文能看、图片全裂」的成因。

`resolvePostMediaAccess(context, post)` 是唯一判定入口：

```text
post 非 moderated_hidden           → public
moderated_hidden + 作者/管理员      → authorized（Bearer JWT + 私有缓存 + 账号作用域 key）
moderated_hidden + 其他身份         → public（服务端同样 404）
```

`PostMediaView` 新增 `access` 参数（默认 `PostMediaAccess.public()`，向后兼容），
并把它透传到全部解码路径：`_tile` / `_progressiveNetworkImage` / `_networkImage` /
单图状态组件的回退解析 / 全屏 `ImageViewerScreen`（`httpHeaders` +
`cacheManager` + `cacheKeyBuilder`）。

已接入的渲染入口：

| 入口 | 说明 |
| --- | --- |
| `PostMediaView` | 媒体主组件 |
| `PostCard`（含 `CommunityPostCard`） | 我的内容水帖列表、公开流 |
| `PollPostCard` | 我的内容里的投票帖 |
| `SectionPostCard` | 版块流 |
| `MarketPostCard` | 我的主页集市记录（作者本人会拿到 `moderated_hidden`） |
| `my_content_screen` 集市封面 | 改用 `AppCachedImage.private` |
| `post_detail_screen` 详情图与自适应水图 | 直接复用 `PostMediaView` |

`MarketPostCard` 是评审里没提到但同因同源的第二个漏洞面：`/user/:id/posts`、
`/user/:id/market-posts` 在 viewer 是作者本人或管理员时会返回 `moderated_hidden`
（`internal/handlers/user.go`），而该卡片此前硬编码 `PostImageCache.manager`。

## 3. 修复二：整改/申诉结果通知改为可靠写入

原则：**站内通知必须与状态变更原子；外部 Push 继续事务外 best-effort。**

| 位置 | 改动前 | 改动后 |
| --- | --- | --- |
| `ResolveRectification` 通过/驳回 | 事务提交后 `_ = Create...` | 事务内 `CreatePostModerationResultNotification`，失败即回滚 |
| `AdminRestorePost` | 同上 | 事务内写入 |
| `AppealHandler.Review`（人工复核） | 事务外 `_ = Create...` | 事务内 `writeAppealAppellantNotification` |
| `AppealHandler.VoteMore`（投票即时结案） | 事务外 `_ = Create...` | 三条结案出口统一走 `closeAppealAndNotify` |
| `tasks.FinalizeExpiredAppeals`（到期兜底） | 事务内 `createAppealTaskNotification` | 改为共用同一决策函数 |

幂等性由既有 `dedupKey + ON CONFLICT DO NOTHING`（唯一索引
`idx_notification_dedup`）保证，事务重试与定时任务重跑都不会重复提醒。

事务外的 fan-out（管理员、陪审员）仍保留，但走 `sendAppealNotification`，
失败会留下 `[APPEAL_NOTIFICATION_FAILED]` 日志 —— 不是 `_ = ...`。

## 4. 修复三：一次结案只给申诉人一条通知

新增 `models.ResolveAppealAppellantNotification(appeal, closedByHumanReview)
→ {Type, Content, DedupKey, PostScoped}`。

抽到 `models` 层的原因：即时结案（handlers）与到期兜底结案（tasks）必须得出完全
相同的结论，而 `tasks` 不能反向依赖 `handlers`（`handlers/lottery.go` 已依赖
`tasks`，形成环）。

```text
post 目标 + pass  → appeal_approved  「帖子的限制已解除，现已恢复正常公开展示」
                    PostScoped=true，dedup=appeal-approved:<appealId>
post 目标 + reject → appeal_rejected  维持原处理结果，提示仍可继续整改
reply / 其他目标   → appeal_result    公众法庭维度（PostID 只是所属帖子，
                                      不能向申诉人宣称「帖子已恢复展示」）
Review（转人工）    → appeal_review_required
```

`PostScoped=true` 的通知写入 `PostID`，客户端 `notifications_screen` 据此直达
`PostDetailScreen`。

### 配套：帖子治理结果区的申诉详情入口

既然主通知改挂帖子维度，作者点进帖子后必须能回到公众法庭。为此：

- `PostViewerPermissions` 新增 `latest_appeal_id`（优先未决案件，其次最近一次已结案），
  仅在 `moderated_hidden` 且 viewer 是作者/管理员时下发；
- 帖子详情的治理横幅新增「查看申诉进度 / 查看申诉详情」按钮，跳 `CourtScreen`。

## 5. 修复四：管理端整改卡补齐审核依据

`ListRectification` 由直接返回 `models.PostRectificationReview` 改为返回
`rectificationAdminItem`（内嵌 review，响应字段向后兼容）：

```text
original_rule_code    治理时确认的违规规则码（harassment → 人身攻击）
original_reason       管理员处理说明
report_reason_code    举报分类码（归类参考）
moderated_revision    处理时内容版本
moderated_snapshot    处理时内容快照（Report.TargetSnapshot）
moderated_at          处理时间
```

不使用 `models.Report` 直接序列化的原因：它会带上 `reporter_id` 与举报人自述，
不属于审核依据。`PostRectificationReview.Report` 关联字段标记 `json:"-"`，
并有测试断言 `reporter_id`、举报人昵称、举报人自述都不出现在响应里。

举报记录缺失（历史数据）时降级：先按帖子回查最近一次 `moderated_hidden` 举报，
仍查不到则只下发帖子字段并从帖子回填 `moderation_rule_code` / `moderation_reason`，
卡片降级展示而不是整体失败。

客户端卡片：

```text
帖子整改复审
帖子 #123 · 处理版本 v3 → 整改版本 v4                    [查看整改后帖子]

┌ 治理依据 ─────────────────────────────────────┐
│ 原处理原因   人身攻击                          │
│ 管理员说明   请删除针对具体同学的攻击内容       │
│ 处理时间     2026-09-16 12:03                  │
└───────────────────────────────────────────────┘

┌ 整改后内容 ───────────────────────────────────┐
│ 标题 / 正文前 120 字                           │
└───────────────────────────────────────────────┘
[查看处理时内容]                                  [驳回] [通过并恢复]
```

- 「查看原帖」→「查看整改后帖子」：文案必须与实际打开的内容一致；
- 「查看处理时内容」弹窗展示解析后的 `moderated_snapshot`（标题/正文/图片数量），
  快照缺失时按钮置灰并显示「处理时内容不可用」；
- 原因码中文映射抽到 `client/lib/utils/report_reason_label.dart`，与
  `admin_reports_screen` 共用，避免两处各维护一份映射表而漂移。

## 6. 修复五：过期待办 409 自动刷新

`_rectificationConflictMessage` 专门识别：

```text
409 content_revision_changed  → 作者已更新内容，这条整改任务已失效，正在刷新最新待办
409 review_already_resolved   → 该整改任务已被其他管理员处理，正在刷新最新待办
```

提示后立即 `await _loadData()`，过期卡片不会留在列表里让管理员反复点到 409。

## 7. 变更文件

服务端：

```text
internal/models/appeal_notification.go            新增（申诉人主通知决策）
internal/models/appeal_notification_test.go       新增
internal/models/post.go                           PostViewerPermissions.LatestAppealID
internal/models/report.go                         PostRectificationReview.Report 关联（json:"-"）
internal/handlers/post_governance.go              待办 DTO + 通知入事务
internal/handlers/post_governance_admin_item_test.go 新增
internal/handlers/appeal.go                       通知入事务 + 去重
internal/handlers/post.go                         latest_appeal_id 下发
internal/tasks/appeal_finalizer.go                共用通知决策
```

客户端：

```text
lib/utils/governed_post_image_cache.dart          新增
lib/utils/post_media_access.dart                  新增
lib/utils/report_reason_label.dart                新增
lib/widgets/post_media/post_media_view.dart       access 通道
lib/widgets/post_card.dart                        access 接入
lib/widgets/poll/poll_post_card.dart              access 接入
lib/widgets/water_section/section_post_card.dart  access 接入
lib/widgets/market_post_card.dart                 封面与查看器鉴权
lib/screens/my_content_screen.dart                集市封面私有加载
lib/screens/post_detail_screen.dart               详情鉴权 + 申诉详情入口
lib/screens/admin_review_tasks_screen.dart        审核依据卡 + 409 刷新
lib/screens/admin_reports_screen.dart             共用原因码映射
lib/models/post.dart                              latestAppealId
test/utils/governed_post_image_cache_test.dart    新增
test/widgets/post_media_governed_access_test.dart 新增
```

## 8. 验证

见文末「验证输出」。核心断言：

- 鉴权模式的 `CachedNetworkImage` 不复用 `PostImageCache.manager`，
  且 `cacheKey` 是账号作用域、不含 JWT；
- 整改待办响应不含 `reporter_id` / 举报人自述；
- 帖子类申诉结案不再产出 `appeal-result:<id>:appellant` 命名空间的通知。

## 9. 仍未覆盖（明确记录，不假装完成）

1. **回复类治理的图片**：本次只处理帖子（`moderated_hidden`）图片，回复隐藏走
   `replies.status` 独立链路，未纳入鉴权加载。
2. **水帖页公开图片预取**：`shuitie_screen` 的 `ImagePrefetchCoordinator` 仍按
   公开缓存预热。治理帖不进入公开流，因此不会命中；若将来公开流放开治理帖，
   需要同步接入 `resolvePostMediaAccess`。
3. **Push 深链**：治理结果通知目前只写站内库，没有极光 Push；
   `NotificationOpenTarget.parse` 也只识别 `reply` / `feedback_ticket` 两类。
   治理类通知的 Push 深链是独立课题。
4. **处理时内容快照不含图片**：`Report.TargetSnapshot` 只存
   `image_file_ids`，管理端目前只能看到图片数量，看不到处理时的图片本体。
5. **事务外的管理员/陪审员 fan-out**：保留 best-effort + 失败日志，未做 outbox。
