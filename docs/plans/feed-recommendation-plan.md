# SYLUlive Feed Recommendation 执行计划（轨道 R）

**仓库：** `zhouwu97/SYLUlive`
**正式执行基线：** `MCP`
**基线提交：** `7bdf3a3ac29c1592edf567ce5efd503d31def76e`
**计划类型：** Feed 分发 / 个性化推荐 / 用户控制 / 行为数据
**命名约定：** 本轨道全部使用 `FEED-N`，禁止使用 `UX-N`，避免与 UX 主轨混淆。

---

# 0. 定位

本计划是三条并行轨中的 **轨道 R**，负责：

```text
用户控制 → 曝光数据 → 指标 → 个性化 → 作者关注 → 隐式主题
```

与 UX 主轨（`docs/plans/ux-experience-plan-v3.md`）的唯一交界：

```text
PostProvider
Feed Card（PostCard / CommunityPostCard / PollPostCard）
ShuitieScreen
PostDetailScreen
```

交界点全部设为 merge gate，规则见 UX 计划文末
「21. Parallel Track Conflict Rule」。

## 关键合并门

```text
UX-2 merge → 推荐后端（FEED-0 / FEED-1 / FEED-2）可以开始
UX-7 merge → 推荐 Feed UI（FEED-3）才可以开始
```

## Feed 语义固定

```text
综合 = 推荐
最新 = 服务端时间线（客户端不二次过滤，见 UX-2.8）
精华 = 人工选择
关注 = 主动关注关系时间线
```

首页普通帖子 + 投票都是 Recommendation Candidate。
当前 `HomeFeedServiceWithPoll()` 已经把 Poll 喂进当前排名系统，
禁止以后搞第二套投票推荐。

---

# 1. 文件归属（与 UX 主轨的冲突关系）

| 文件/模块 | UX 主轨 | 本轨道处理 |
| --- | --- | --- |
| `client/lib/screens/shuitie_screen.dart` | UX-1、UX-2、UX-7 附近 | 等 UX-2，部分等 UX-7 |
| `client/lib/providers/post_provider.dart` | UX-2 | UX-2 前禁止动 |
| `client/lib/widgets/post_card.dart` | UX-2、UX-7 | 必须等 UX-7 |
| `client/lib/widgets/community_post_card.dart` | Feed 卡片链路 | 必须等 UX-7 |
| `client/lib/widgets/poll/poll_post_card.dart` | Feed 卡片链路 | 必须等 UX-7 |
| `client/lib/screens/post_detail_screen.dart` | UX-2 | 必须等 UX-2 |
| `server/internal/services/home_feed_ranker.go` | UX 不碰 | 本轨独占 |
| `server/internal/services/home_feed_service.go` | UX 不碰 | 本轨独占 |
| `server/internal/models/post.go`、`handlers/post.go` | UX 基本不碰 | 本轨独占 |

> **推荐后端可以早做，推荐客户端必须等现有 Feed UX 稳定。**

---

# 2. 分支依赖

```text
MCP
 │
 ├── UX-1 → merge MCP
 ├── UX-2 → merge MCP
 │     ├── FEED-0 / FEED-1 / FEED-2 后端可开始
 │     ↓
 ├── UX-3 ~ UX-6
 ├── UX-7 → merge MCP
 │     ↓
 └── FEED-3 推荐客户端接入（基于最新 MCP 创建 branch）
       ↓
     FEED-4 baseline metrics
       ↓
     FEED-5 personalized v1
       ↓
     FEED-6 following authors
       ↓
     FEED-7 topics（P2）
```

---

# 3. FEED-0：Recommendation Preflight

branch：

```text
feed/recommendation-preflight
```

不改 UI。只做代码和协议整理，把推荐系统未来边界确定下来。

## 冻结为 baseline（FEED-0 不改）

```text
home_feed_ranker 权重
10/5/3/2
48h fresh
PlacementPolicy
Poll density
```

当前 ranker 已经相当完整，全部作为公共质量基线。

## 待决事项（FEED-0 内确认）

- 「最新」是否彻底无置顶：产品 IA 决策，仅记录，不在 UX-2 顺手改。
- 明确 `snapshot_session_id` 与 `feed_session_id` 两个概念的边界（见 FEED-2）。

## 状态（2026-08-10）

✅ **已完成**，确认报告见 `docs/plans/feed-preflight-report.md`。
baseline 全部核实（10/5/3/2、48h fresh、PlacementPolicy、Poll density、300+100+100 候选池、Snapshot 无 UserID、10 分钟过期、following 仅 WaterSectionFollow）。
未改任何代码。

---

# 4. FEED-1：显式负反馈后端

> ✅ **已完成并合入 MCP（2026-08-10）**：FEED-1 以单提交并入 MCP `1aa5912d`（与 FEED-2 合并为一个干净提交，测试文件不推送）。
> 模型 / `/api/feed` 5 端点 / `ApplyFeedVisibility` 统一 Scope / Feed 管线接入，`go test ./...` 全绿。

branch：

```text
feed/negative-feedback-backend
```

**没有 Flutter Feed UI**，可在 UX-3 ~ UX-7 期间并行做。

## 4.1 新模型

不要全塞一个巨大 `feed.go`：

```text
server/internal/models/feed_feedback.go
server/internal/models/user_hidden_author.go
```

```go
type FeedFeedback struct {
    ID        uint
    UserID    uint
    PostID    uint

    Action    string
    Source    string

    CreatedAt time.Time
    ExpiresAt *time.Time
}
```

P0 action 只有 `not_interested`。
唯一：`user_id + post_id + action`。
`Source`：`all / time / featured / following`，代表用户在哪里点的。
注意：Source 用于分析，不代表只在那个 Tab 生效。

```go
type UserHiddenAuthor struct {
    ID        uint
    UserID    uint
    AuthorID  uint
    CreatedAt time.Time
}
```

唯一：`user_id + author_id`。不自动过期。

## 4.2 反馈语义

### 不感兴趣（not_interested）

第一版只影响 **综合**。

原因：「最新」和「关注」属于用户主动查看路径，用户跑到那里是主动看内容，
不要偷偷把单帖从最新永久消失。

### 不看TA（hide_author）

用户级 Feed Filter：

```text
综合      隐藏
最新      隐藏
精华      隐藏
关注      隐藏
```

不受影响：

```text
搜索
主页
直接帖子URL
评论区
私信
```

所以：`HideFromFeed != BlockUser`。

### 不看TA 不要顺便取消关注

已有真正的 `UserFollow`（`server/internal/models/user_follow.go`）。
「关注张三 → 不看TA」时保留 `UserFollow`，只新增 `UserHiddenAuthor`。
恢复「不看TA」后，张三自然重新出现在关注流。比后台替用户取消关注合理。

## 4.3 API

统一放 `/api/feed`，不继续堆到 `/posts`：

```http
PUT    /feed/posts/:post_id/not-interested
DELETE /feed/posts/:post_id/not-interested

PUT    /feed/authors/:author_id/hidden
DELETE /feed/authors/:author_id/hidden

GET    /feed/hidden-authors
```

## 4.4 服务

新增 `server/internal/services/feed_visibility_service.go`：

```text
GetHiddenAuthorIDs()
GetNotInterestedPostIDs()
HideAuthor()
RestoreAuthor()
MarkNotInterested()
UndoNotInterested()
```

统一 Query Scope：

```go
ApplyFeedVisibility(query, userID, feedKind)
```

禁止把 `NOT IN hiddenAuthorIDs` 复制到四个 Handler。

---

# 5. FEED-2：曝光后端基础设施

> ✅ **已完成并合入 MCP（2026-08-10）**：FEED-2 以单提交并入 MCP `1aa5912d`（与 FEED-1 合并为一个干净提交，测试文件不推送）。
> FeedImpression 模型 / `POST /api/feed/events/batch`（幂等）/ `CleanupExpired` TTL 原语，`go test ./...` 全绿。
> TTL 聚合 cron 归 FEED-4。

branch：

```text
feed/impression-backend
```

依然不动 Flutter Feed UI。

## 5.1 模型

```go
type FeedImpression struct {
    ID uint

    UserID uint
    PostID uint

    FeedSessionID string
    FeedKind      string
    Position      int

    AlgorithmVersion string

    VisibleMS int

    OpenedAt *time.Time
    DwellMS   int

    CreatedAt time.Time
    UpdatedAt time.Time
}
```

唯一：`user_id + feed_session_id + feed_kind + post_id`。

## 5.2 不要再造 like/reply event 表

现有 `Like`、`Reply` 已是真实行为来源，推荐系统直接聚合现有表。
缺的只有：`impression`、`open`、`dwell`，不是点赞本身。

## 5.3 Feed event API

```http
POST /feed/events/batch
```

事件：`impression`、`open`、`dwell`。全部幂等：

- Impression：upsert。
- Open：`opened_at = earliest non-null value`，重复发送不增加数量。
- Dwell：`dwell_ms = max(old, new)`，禁止 `+=`，否则重试一次阅读时长翻倍。

这样甚至不必先增加 EventReceipt 表。

## 5.4 Feed Session 与 Snapshot Session 分开

当前综合流的 `session_id` 实际是服务端 10 分钟分页 Snapshot ID。
明确两个概念：

```text
snapshot_session_id  → 服务端分页快照
feed_session_id      → 分析事件专用
```

网络协议为兼容可继续用 `session_id` 代表 snapshot；
分析事件必须使用 `feed_session_id`。千万不要混。

## 5.5 Raw 数据 TTL

```text
feed_impressions 只保留 30 天
```

然后聚合到 `feed_daily_metrics` 长期留。
避免一年以后几百万条没用的曝光明细。

---

# 6. FEED-3：客户端反馈 + 曝光（等 UX-7）

branch：

```text
feed/user-control-ui
```

**必须基于 UX-7 已合并的新 MCP 创建**。UX-7 本身要重构 PostCard 信息层级，
此时再看最终 Card 结构，而不是提前写然后被 UX-7 推翻。

## 6.1 统一 Action Menu

新增 `client/lib/widgets/feed/feed_post_action_menu.dart`，
由 `CommunityPostCard` 传递给 `PostCard` / `PollPostCard`，
而不是普通帖子一套、投票一套（当前确实是 `CommunityPostCard → PollPostCard/PostCard` 两路）。

菜单：

```text
不感兴趣
不看 TA
举报
```

P2 之前没有「减少类似内容」。

## 6.2 复用 UX-2 完成后的 Provider 状态能力

UX-2 已统一 `PostProvider` optimistic mutation：
`updatePostInCache()` / `applyExternalPostUpdate()`。
推荐 UI 禁止再做 StatefulWidget 本地删除帖子。

UX-2 合入后，PostProvider 再增加：

```dart
hidePostLocally(...)
restorePostLocally(...)

hideAuthorLocally(...)
restoreAuthorLocally(...)
```

统一更新 `all / time / featured / following`。

用户点击后：

```text
立即卡片消失 → API → 失败 rollback
```

完全沿用 UX-2 的 optimistic 合同。

## 6.3 FeedExposureTracker

统一挂在：

```text
FeedExposureTracker
   └── CommunityPostCard
```

而不是改 `PostCard` 自己测可见度。任何特殊卡（Poll / 普通 Post）都统一。

有效曝光定义：

```text
>= 50% visible
连续 >= 700ms
```

## 6.4 FeedEventService

新增：

```text
client/lib/services/feed_event_service.dart
client/lib/services/feed_session_service.dart
client/lib/models/feed_origin_context.dart
```

禁止塞入 `PostProvider`：

```text
PostProvider      = 帖子数据/状态
FeedEventService  = 行为采集
```

职责不同。

## 6.5 Feed Session 语义与 UX-2 Freshness 对齐

UX-2 规则：后台 refresh 不得破坏阅读。事件层服从它。

### 新建 session

```text
首次进入 Feed
手动下拉刷新并正式应用新 snapshot
后台超过 30 分钟
切换账号
```

### 不新建 session

```text
freshness probe
出现「内容有更新」但用户还没点
进入详情再返回
继续 loadmore
```

特别重要：**Freshness Probe 不能偷偷切 FeedSession**。
直到用户真正点击「内容有更新」并应用新列表，才创建新的 FeedSession，数据才干净。

---

# 7. FEED-4：指标基线

> 📐 **设计已完成（2026-08-10）**：`docs/plans/feed4-metrics-design.md`（feed_daily_metrics schema + 六项指标 SQL 口径 + TTL 布线）。
> ✅ **Core 已实现并合入 MCP**：每日聚合 cron + 30 天 TTL（`feed_metrics_cron.go`）；FEED-H1 已修 CTR 分母 / Asia/Shanghai 时区 / interaction density scope。
> **剩余待门禁**：FEED-3 客户端事件流入 + 真实数据积累（报告完整性 / baseline 验收）。

在任何 P1 个性化之前先跑 baseline。

### CTR

```text
unique opens
────────────
valid impressions
```

分别统计 `all / time / featured / following`。

### Interaction density

```text
likes + replies + poll votes
─────────────────────────── ×1000
impressions
```

### Negative feedback

```text
not_interested
hide_author
```

per 1000 impressions。

### 多样性

前 20：`distinct author`、`distinct section`。

### 新帖公平性

```text
发布后 24h 达到 20 次有效曝光的比例
```

先测。当前 Ranker 已有 48h fresh slot，不要没数据就又上「试投」。

### 冷启动

```text
注册后前 3 个 FeedSession 的综合 CTR
```

P1 上线后不能变差。

---

# 8. FEED-5：个性化排名 v1（P1）

branch：

```text
feed/personalized-ranking-v1
```

这里才动：

```text
server/internal/services/home_feed_service.go
server/internal/services/home_feed_ranker.go
server/internal/models/post.go
```

**不重写现有 Ranker。** 当前 Quality / HotScore / ActivityScore / 10/5/3/2 /
PlacementPolicy 全部作为公共质量基线。

## 8.1 推荐架构

```text
公共候选采集
  300 + 100 + 100
        ↓
现有 Global Score
        ↓
显式过滤
 ├─ hidden author
 └─ not interested
        ↓
User Features
        ↓
Personal Delta
        ↓
现有 Placement Policy
        ↓
Exploration
        ↓
用户专属 Snapshot
```

## 8.2 P1 只用这些特征

```text
AuthorAffinity
SectionAffinity
FollowSignal
Freshness adjustment
SeenPenalty
```

不做 `ContentInterest / SimilarPost / TopicAffinity`（这些是 P2）。

## 8.3 UserFeatures

新增 `server/internal/services/home_feed_user_features.go`，批量取：

```text
最近 30 天 likes
最近 30 天 replies
最近 30 天 opens
最近 30 天 dwell
UserFollow
WaterSectionFollow
recent impressions
```

禁止「500 个 candidate → 每个 candidate 查一次 DB」，必须先聚合成 map。

## 8.4 分数模型

```text
FinalRelevance = BaseRelevance + PersonalDelta
```

而不是重新发明完整 0.4A+0.3B 模型。PersonalDelta 先限制范围：

```text
-0.30 ~ +0.30
```

避免用户画像一上线就把公共质量全部压没。

## 8.5 AuthorAffinity

按最近行为，时间衰减，不需要永久累计：

```text
关注作者   强
回复作者   强
点赞作者   中
长阅读     中
打开       弱
```

## 8.6 SectionAffinity

只靠现有 7 个弱版块行为：关注 / reply / like / open / dwell。
完全不依赖贴吧式标签。

## 8.7 SeenPenalty

```text
第一次曝光未打开            → 0 penalty
不同 FeedSession 曝光 >=2 且从未打开 → weak penalty
open 过                    → 不算 Seen negative
long dwell                 → positive
not_interested             → hard filter
```

## 8.8 探索（不写成分数）

第一页 20 条：17 个正常 personalized + 3 个 explore（例如 5 / 11 / 17）。
探索来源：低曝光新作者、用户较少接触版块、新帖。明确保证约 15%。

## 8.9 Snapshot 加 UserID

当前 `Snapshot`（`server/internal/handlers/post.go`）还没有 UserID。P1：

```go
type Snapshot struct {
    UserID uint

    PostIDs []uint

    ExpiredAt time.Time

    AlgorithmVersion string
    Sort string
    FeedKind string
}
```

loadmore：

```text
snapshot.UserID != currentUser → feed_session_expired
```

## 8.10 Rank Trace

P1 必须同时加，只采样 5%：

```text
base_relevance
author_affinity
section_affinity
follow_signal
seen_penalty
personal_delta
final_relevance
reason_codes
```

否则以后权重没法调。

---

# 9. FEED-6：关注流（following authors）

当前 `following` 仍然只有 `WaterSectionFollow`。正式改成：

```text
UserFollow
UNION
WaterSectionFollow
```

按 `created_at DESC`。

第一版关注流**不要个性化**：

> 综合负责「猜你想看」，关注负责「我明确选择看」。

双命中（关注作者 + 关注版块）只出现一次。

---

# 10. FEED-7：P2 内容主题

等 P1 数据稳定后。增加 `post_features`：

```text
来源：post_type / water_tag / title / content / 校园领域词典 / n-gram
```

不需要 jieba / embedding / LLM。

例如：蓝桥杯、ICPC、二课、高数、四六级、宿舍、食堂、图书馆、工训中心、考研、补考。

## 「减少类似内容」

到 P2 才上线，菜单才变成：

```text
不感兴趣
减少类似内容
不看TA
举报
```

因为「类似」这时终于有了 Topic，而不是现在假装知道什么叫类似。

---

# 11. 分支清单汇总

| 编号 | branch | 门禁 | 状态 |
| --- | --- | --- | --- |
| FEED-0 | `feed/recommendation-preflight` | UX-2 合入后 | ✅ 已完成（preflight 报告） |
| FEED-1 | `feed/negative-feedback-backend` | UX-2 合入后 | ✅ **已合入 MCP `1aa5912d`** |
| FEED-2 | `feed/impression-backend` | UX-2 合入后 | ✅ **已合入 MCP `1aa5912d`** |
| FEED-H1 | `feed/backend-hardening` | UX 合回 MCP 后 | ✅ **本阶段已实现**（Snapshot UserID / 反馈失效 / 自反馈守卫 / 90 天过期 / 缓存隔离 / metrics 口径时区 scope） |
| FEED-3 | `feed/user-control-ui` | UX-7 合入后（必须基于最新 MCP） | ✅ UX-7 已合入 MCP，门禁解除；待 FEED-H1 合入后开始 |
| FEED-4 | baseline metrics（可并 FEED-3 数据落地后启动） | FEED-2/3 数据可用 | ✅ Core 已实现并合入 MCP；⛔ 报告/验收待 FEED-3 真实数据 |
| FEED-5 | `feed/personalized-ranking-v1` | FEED-4 baseline | ✅ **工程已实现并合入 MCP**（UserFeatures/delta/exploration/trace/flag/shadow）；⛔ active rollout 待真实数据 ≥500 曝光 + ≥30 open |
| FEED-6 | `feed/following-authors` | 不依赖个性化（可提前） | ✅ **本阶段已实现并合入 MCP**（关注作者 + 关注版块；hidden > following） |
| FEED-7 | topics（P2） | P1 数据稳定后 | ⛔ 依赖 P1 |

## 硬规则

执行 UX 计划文末「21. Parallel Track Conflict Rule」全部条款。
每创建一个新 branch，必须从最新 `origin/MCP` 创建，
不允许长期基于旧 feature branch 串联。

---

# 12. 合入 MCP 注意事项（2026-08-10 分析 + 已实测验证）

> ✅ **2026-08-10 已用临时 worktree 实测**：将 FEED-2 merge 进 FEED-1 分支，
> 真实冲突与以下预判完全一致（`server/API.md` + `server/cmd/main.go` 两文件）；
> 按本节方案解决后 `go build` + `go vet` + 全量测试全部通过，临时分支已清理。

FEED-1 与 FEED-2 是**基于同一 origin/MCP（`7bdf3a3a`）的并行分支**，
模型/服务/handler 文件互不重叠，但以下两处会冲突，合并时必须手动协调：

## 12.1 `server/cmd/main.go` —— `feed` 路由组重复声明

两分支都在同一位置声明了同名变量：

```go
feed := r.Group("/api/feed")
feed.Use(middleware.AuthMiddleware(db, cfg.JWTSecret))
```

- FEED-1（`84206ff7`）：`/posts/:post_id/not-interested`、`/authors/:author_id/hidden`、`/hidden-authors` 共 5 端点；
- FEED-2（`93f30be3`）：`/events/batch` 共 1 端点。

**合并方式**：后合入者 rebase 到最新 MCP 后，不重复声明 `feed` 组，
把端点并入已有的 `feed` 组块即可（两个 handler 构造 `feedHandler` / `feedEventHandler` 可各自保留）。
另外两分支的 AutoMigrate 增加项（`FeedFeedback`/`UserHiddenAuthor` vs `FeedImpression`）行不同，git 可自动合并，无需处理。

## 12.2 `server/API.md` —— 两个 `## 4.1` 章节

- FEED-1 加了 `## 4.1 Feed 推荐用户控制 (Feed) — FEED-1`；
- FEED-2 加了 `## 4.1 Feed 行为事件采集 (Feed Events) — FEED-2`。

**合并方式**：保留两个 4.1 子节（改名为 `4.1 Feed 推荐用户控制` / `4.2 Feed 行为事件采集`），
目录同步更新。

## 12.3 建议合并顺序

```text
FEED-1 → MCP
FEED-2 rebase MCP → MCP
```

先合 FEED-1 再合 FEED-2（或反之均可），第 12.1/12.2 的手动协调点不变。
