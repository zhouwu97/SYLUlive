# FEED-0：Recommendation Preflight 确认报告

**日期：** 2026-08-10
**基线：** `MCP` @ `7bdf3a3ac29c1592edf567ce5efd503d31def76e`
**性质：** 纯代码与协议整理，未改任何代码（FEED-0 冻结 baseline）
**依据：** `docs/plans/feed-recommendation-plan.md`（轨道 R）

---

# 1. 结论摘要

- 现有排名系统结构完整，与轨道 R 计划的「baseline 冻结」描述一致，可以原样作为公共质量基线。
- 首页普通帖子 + 投票已经共用一个排名管线（`HomeFeedServiceWithPoll`），不存在第二套投票推荐。
- Snapshot 无 UserID、10 分钟过期、`feed_session_expired` 语义均已存在，FEED-5 的 Snapshot UserID 改造点明确。
- 置顶（`pinned_posts`）与普通快照完全分离，FEED-0 期间确认「最新是否无置顶」为产品 IA 决策，留给后续阶段，不在本轮处理。
- **门禁状态：** UX-2 尚未合入（MCP HEAD 仍为 `7bdf3a3a`），按 Parallel Track Conflict Rule，FEED-1/FEED-2 后端代码未开始。

---

# 2. Feed 语义边界确认

| Tab | 语义 | 当前代码事实 |
| --- | --- | --- |
| 综合 `all` | 推荐（排名快照） | `handlers/post.go:479-480`：`sort == "all"` 走 `BuildSnapshot` → `RankHomeFeed` → `applyPollDensity` |
| 最新 `time` | 服务端时间线 | `handlers/post.go:987-992`：`sortName == "time"` 使用 `created_at DESC`；客户端 UX-2.8 将删除二次过滤 |
| 精华 `featured` | 人工选择 | `post.go:509-511`：`sort == "featured"` 分支 |
| 关注 `following` | 主动关注关系时间线 | `post.go:420-435`：当前 **仅** `WaterSectionFollow`（版块关注），FEED-6 将 UNION `UserFollow` |

确认：`综合 = 推荐` 语义成立；`关注` 目前只含版块关注，作者关注缺失（FEED-6 范围）。

---

# 3. Recommendation Candidate 范围确认

- `NewHomeFeedServiceWithPoll()`（`services/home_feed_service.go:16`）→ `includePoll = true`。
- `BuildSnapshot` 候选采集 = 3 个池（`home_feed_service.go:46-54`）：

```text
300 条  30 天内 created_at DESC
100 条  72h 内有活动（reply_count > 0）且 180 天内
100 条  180 天内 featured
```

- 去重后 `< 100` 时兜底取 `created_at DESC` 前 500（`:63-74`）。
- Poll 通过 `pollByPost` map 批量装载，进入 `HomeFeedCandidate`（`IsPoll / PollLastVoteAt / ParticipantCount / PollEnded`），再 `applyPollDensity`（`:114-117`）。

**确认：首页普通帖子 + 投票共用一个推荐管线，不存在第二套投票推荐。**
FEED 轨道后续不得另起投票推荐系统。

---

# 4. Baseline 冻结清单（代码事实）

以下全部为现有实现，FEED-0 冻结，后续个性化只做增量：

| 项 | 代码位置 | 现状 |
| --- | --- | --- |
| Quality 公式 | `home_feed_ranker.go:26-28` | `4·ln(1+likes) + 6·ln(1+uniqueRepliers) + 2·ln(1+effectiveReplies) + 0.8·ln(1+views)`；`effectiveReplies = min(ReplyCount, uniqueRepliers*3+5)` |
| HotScore | `:35` | `(6 + Q) / (age_h + 6)^0.9` |
| ActivityScore | `:36` | `(4 + Q) / (activityAge_h + 4)^0.8` |
| Poll 加成 | `:37-50` | 参与加成 ≤ 3.5，投票活跃加成 ≤ 3（12h 半衰），已结束 ×0.35 |
| 槽位 10/5/3/2 | `:145-152` | byHot 10（7 天内）＋ byFresh 5（48h 内）＋ byActivity 3（72h 内且 reply>0）＋ byFeatured 2（180 天内） |
| 48h fresh | `:146` | `created_at >= now-48h` |
| PlacementPolicy | `:53-95, 250-285` | Strict / Relaxed1 / Relaxed2 / FinalFill 四级放宽；作者/版块/老帖密度约束 |
| 第一页 20 条 | `:131, 156` | 前 20 走槽位+密度，其余按 byHot 追加 |
| Poll density | `home_feed_service.go:124-151` | 每 5 条正常内容至少插 1 条投票（`normalSincePoll >= 5`），末尾兜底 |
| 快照截断 | `:118-120` | 最多 500 |

---

# 5. Snapshot / Session 现状（FEED-5/6 的改造点）

```go
// handlers/post.go:37-43
type Snapshot struct {
    PostIDs          []uint
    ExpiredAt        time.Time
    AlgorithmVersion string
    Sort             string
    FeedKind         string
    // 无 UserID —— FEED-5 增加
}
```

- `ActiveSnapshots`（`post.go:45`）：`sync.Map`，key = `session_id`，过期 10 分钟（`:604, 1016`）。
- `feed_session_expired`（`:640, 999`）：快照过期 / sort / algorithm_version / feed_kind 不匹配 → 409 冲突。
- 置顶完全独立：`PinnedPosts()`（`home_feed_service.go:20-28`，最多 3 条）与 `BuildSnapshot` 分离，响应体 `pinned_posts` 与 `posts` 分列（`post.go:1058`）。
- `FeedKind` 现值：`"generic"` / `"generic_poll_v1"`（`post.go:231-233`）、`"home_v3_poll"`（`:978`）。
- 协议中 `session_id` = 服务端 Snapshot ID。

**协议决策（FEED-2）：**
- `session_id` 继续代表 snapshot（兼容现有客户端）。
- 分析事件使用新的 `feed_session_id`，与 snapshot 分离。
- FEED-5 时 `Snapshot.UserID != currentUser → feed_session_expired`。

---

# 6. FEED-1 插入点分析（供开工使用，未写代码）

负反馈过滤的唯一插入点：

```text
HomeFeedService.BuildSnapshot(now) → base() 查询（home_feed_service.go:30-36）
```

- `base()` 目前无用户维度。FEED-1 需为 `BuildSnapshot` 增加 `userID` 参数（或独立方法），
  在 `base()` 追加：

```text
NOT EXISTS hidden_author（不看TA：所有 feedKind）
NOT IN not_interested（不感兴趣：仅 all feedKind）
```

- `PinnedPosts` 是否过滤 hidden author：按计划语义，「不看TA」覆盖综合/最新/精华/关注，
  置顶属于综合流的一部分，FEED-3 UI 上线时与卡片链路一起定（不影响 FEED-1 模型层）。
- `handlers/post.go:997-1017` 的 snapshot 创建路径是第二个接入点（loadmore 一致性校验）。

禁止把 `NOT IN hiddenAuthorIDs` 复制到四个 handler —— 统一 `ApplyFeedVisibility(query, userID, feedKind)`。

---

# 7. 待决事项（FEED-0 记录，不在本轮决策）

1. **「最新」是否彻底无置顶**：产品 IA 决策。服务端已分离 pinned，客户端 `time` 分支是否排除 pinned 留待 UX-2 合入后的 FEED 阶段确认。
2. **AlgorithmVersion 命名**：现为 `generic_poll_v1` / `home_v3_poll`，FEED-5 个性化后需新版本号（如 `home_personal_v1`），Rank Trace 5% 采样随之启用。
3. **FEED-4 指标表名**：`feed_daily_metrics` 字段集在 FEED-2 建表时一并确定。

---

# 8. 门禁状态

```text
UX-2 merge → FEED-1 后端可开始（模型 / API / ApplyFeedVisibility）
UX-7 merge → FEED-3 客户端 UI 可开始
```

当前：UX-2 未合入，FEED-0 完成，FEED-1 等待门禁。
