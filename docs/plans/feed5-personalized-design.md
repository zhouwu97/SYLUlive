# FEED-5：个性化排名 v1 设计（设计先行，实现待门禁）

**日期：** 2026-08-10
**性质：** 纯分析文档，未写任何代码
**前置依赖：** FEED-4 指标基线数据积累；FEED-1（负反馈表）与 FEED-2（曝光表）已合入 MCP；FEED-H1 已完成 Snapshot.UserID 绑定、反馈失效、90 天 not_interested 过期

---

# 0. 为什么现在先出设计

FEED-5 的实现被以下门禁卡住：

```text
1. FEED-1 / FEED-2 已合入 MCP（表已在 origin/MCP）；FEED-H1 已完成 Snapshot.UserID 绑定 / 反馈失效 / 90 天过期
2. FEED-4 基线指标需要真实数据积累（依赖 FEED-3 客户端事件流入，而 FEED-3 依赖 UX-7）
3. 权重调参需要 Rank Trace 数据支撑，不能凭空虚设
```

与 FEED-4 相同：**设计先行**，门禁一开即可直接实现。

---

# 1. 代码事实基线（已核实）

| 事实 | 位置 | 说明 |
| --- | --- | --- |
| `BuildSnapshot(now, userID)` | `services/home_feed_service.go`（FEED-1 分支） | FEED-1 已把 userID 注入，负反馈过滤已在 base() 生效 |
| 候选池 300+100+100 | `home_feed_service.go:46-54` | 30 天新帖 300 + 72h 活跃 100 + 180 天精华 100 |
| Global Score | `home_feed_ranker.go` | Quality/HotScore/ActivityScore 公式冻结为 baseline |
| 槽位 10/5/3/2 + 48h fresh | `home_feed_ranker.go:145-152` | byHot/byFresh/byActivity/byFeatured |
| PlacementPolicy | `home_feed_ranker.go:53-95` | Strict/Relaxed1/Relaxed2/FinalFill |
| Poll density | `home_feed_service.go:124-151` | 每 5 条正常插 1 投票 |
| Snapshot 已含 UserID | `handlers/post.go:37-47` | FEED-H1 已加 `UserID` 并做 loadmore 归属校验；FEED-5 复用并扩展 |
| `feed_session_expired` | `handlers/post.go:999` | 409 冲突码已存在，FEED-5 复用 |

---

# 2. 推荐架构（最终形态）

```text
公共候选采集
  300 + 100 + 100
        ↓
现有 Global Score（冻结 baseline）
        ↓
显式过滤
 ├─ hidden author（FEED-1：所有 feedKind）
 └─ not interested（FEED-1：仅 all）
        ↓
User Features（批量聚合，不逐候选查 DB）
        ↓
Personal Delta（-0.30 ~ +0.30，叠加到 Global Score）
        ↓
现有 Placement Policy（不变）
        ↓
Exploration（20 条中 3 条探索槽）
        ↓
用户专属 Snapshot（带 UserID，10 分钟）
```

**核心原则：`FinalRelevance = BaseRelevance + PersonalDelta`，不重写现有 Ranker。**

---

# 3. P1 特征集（明确边界）

P1 只用：

```text
AuthorAffinity
SectionAffinity
FollowSignal
Freshness adjustment
SeenPenalty
```

**不做**（这些是 P2）：

```text
ContentInterest
SimilarPost
TopicAffinity
```

> 设计决策：P1 公式里不要出现恒为 0 的 `ContentInterest` 死分量。
> 等 P2 有 `post_features` 后再并入，避免占着权重却无数据。

---

# 4. UserFeatures 批量聚合

新增 `server/internal/services/home_feed_user_features.go`：

```text
批量取（一次查询聚合为 map，禁止 500 候选 × 每候选查一次 DB）：
  最近 30 天 likes（按 author_id / post_type 聚合）
  最近 30 天 replies
  最近 30 天 opens（feed_impressions.opened_at 非空）
  最近 30 天 dwell（feed_impressions.dwell_ms 聚合）
  UserFollow（关注作者集合）
  WaterSectionFollow（关注版块集合）
  recent impressions（最近曝光过的 post 集合，供 SeenPenalty）
```

数据结构建议：

```go
type UserFeedFeatures struct {
    UserID uint

    LikedAuthorCount    map[uint]float64 // author_id → 权重（时间衰减）
    RepliedAuthorCount  map[uint]float64
    OpenedAuthorCount   map[uint]float64
    DwellByAuthorMS     map[uint]int64

    LikedSectionCount   map[string]float64 // post_type → 权重
    OpenedSectionCount  map[string]float64

    FollowedAuthors     map[uint]bool
    FollowedSections    map[string]bool

    SeenPostIDs         map[uint]bool     // 最近曝光过的 post
    SeenSessionsByPost  map[uint]int      // 不同 FeedSession 曝光次数（SeenPenalty 用）
}
```

时间衰减：按天衰减，`weight *= pow(0.95, daysAgo)`，30 天窗口足够，不需要永久累计。

---

# 5. 分数模型

```text
FinalRelevance = BaseRelevance + PersonalDelta
```

- `BaseRelevance` = 现有 `ScoreHomeFeedCandidate` 产出的 Global Score（冻结）。
- `PersonalDelta` 先限制范围：**-0.30 ~ +0.30**。
- 避免用户画像一上线就把公共质量全部压没。

分量建议（工程初始值，不是最优值，依赖 Rank Trace 调参）：

```text
AuthorAffinity   +0.10 max
SectionAffinity  +0.06 max
FollowSignal     +0.08 max（关注作者刚发的新帖给强信号）
Freshness        +0.04 max（48h 新帖小幅加成）
SeenPenalty      -0.15 max（仅「曝光≥2 次且从未 open」）
```

---

# 6. AuthorAffinity

按最近行为 + 时间衰减，不需要永久累计：

```text
关注作者       强   （+1.0 权重）
回复作者       强   （+0.8）
点赞作者       中   （+0.5）
长阅读（dwell 高）中 （+0.4）
打开           弱   （+0.2）
```

---

# 7. SectionAffinity

只靠现有 7 个弱版块 + 行为：

```text
关注版块  reply  like  open  dwell
```

完全不依赖贴吧式标签。P2 之前没有 `post_features` 主题。

---

# 8. SeenPenalty（固定规则）

```text
第一次曝光未打开                    → 0 penalty
不同 FeedSession 曝光 >=2 且从未打开 → weak penalty（-0.15 max）
open 过                            → 不算 Seen negative
long dwell（> 阈值）               → positive（进 AuthorAffinity 长阅读）
not_interested                     → hard filter（FEED-1 已过滤）
```

> 设计要点：不要「曝光过就降权」一刀切，否则新帖被展示一次没点就被惩罚，
> 对新帖公平性（FEED-4 指标）致命。只惩罚「多次曝光从未打开」。

---

# 9. 探索（不写成一个分数）

第一页 20 条：

```text
17 个正常 personalized
3 个 explore
```

槽位示例：`5 / 11 / 17`（第 5、11、17 位是探索槽）。

探索来源：

```text
低曝光新作者
用户较少接触版块
新帖
```

明确保证约 15%。Explore 不参与 PersonalDelta，直接用公共质量分占槽。

---

# 10. Snapshot 加 UserID

FEED-H1 已按此结构落地 `Snapshot.UserID` 与 loadmore 归属校验（见 `handlers/post.go`）；FEED-5 保持并复用：

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

loadmore 校验：

```text
snapshot.UserID != currentUser → feed_session_expired（复用 409）
```

> 注意：FEED-1 的 `BuildSnapshot(now, userID)` 已把 userID 传入排序；
> FEED-H1 已把 userID 存进 Snapshot 并做 loadmore 校验（当前实现见
> `handlers/post.go` 的 `getHomeFeedV2` / `getLegacyHomeFeedCompat`），
> 个性化 session 已真正绑定用户。

---

# 11. Rank Trace（P1 必须同时加）

只采样 5% 请求，记录：

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

存储建议：

```text
新表 feed_rank_traces（或 feed_daily_metrics 内嵌 JSON 明细）
保留 30 天，与 feed_impressions 同步 TTL
```

> 否则以后权重根本没法调。FEED-4 的指标 + FEED-5 的 trace 是调参的两条腿。

---

# 12. 实现清单（门禁一开按此执行）

| 步骤 | 内容 |
| --- | --- |
| 1 | `models/feed_impression.go` 加 `Snapshot.UserID` 字段（`handlers/post.go`） |
| 2 | `services/home_feed_user_features.go`：批量聚合（第 4 节） |
| 3 | `services/home_feed_ranker.go`：新增 `ApplyPersonalization(candidates, features, now)`，产出 PersonalDelta |
| 4 | `services/home_feed_service.go`：`BuildSnapshot` 内串联 显式过滤 → PersonalDelta → 探索槽 |
| 5 | `handlers/post.go`：Snapshot 存 UserID + loadmore 校验 |
| 6 | `services/feed_rank_trace.go`：5% 采样写入 |
| 7 | 单测：PersonalDelta 边界（±0.30）、SeenPenalty 规则、探索槽占比、Snapshot UserID 校验 |
| 8 | `cmd/main.go`：AutoMigrate 新表 + API.md |
| 9 | 分支 `feed/personalized-ranking-v1`，基于最新 origin/MCP |

---

# 13. 门禁状态

```text
FEED-5 实现条件：
  [x] FEED-1 / FEED-2 合入 MCP（已合入）
  [x] Snapshot.UserID 绑定 / loadmore 校验 / 反馈失效（FEED-H1 已落地）
  [x] FEED-4 Core + FEED-4B 管理端点（已实现）
  [x] FEED-3 客户端事件流入（已实现，等待真实流量）
  [x] FEED-5 工程（UserFeatures / delta / exploration / trace / flag / shadow）—— 已实现并合入 MCP
  [ ] 真实有效曝光 ≥500 + open ≥30 —— 只阻塞 active rollout（PHASE 15 灰度），不阻塞 shadow

当前：FEED-5 工程完成，shadow 已启用（percent=0，不改用户排序）；等真实数据达标后再灰度。
```
