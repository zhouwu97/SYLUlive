# FEED-4：指标基线（设计 + Core 已实现；报告/验收待门禁）

**日期：** 2026-08-10
**性质：** 设计文档；FEED-4 Core 聚合已实现并合入 MCP（`feed_daily_metrics` 每日 cron + 30 天 TTL）
**前置依赖：** FEED-1（`FeedFeedback` / `UserHiddenAuthor`）、FEED-2（`FeedImpression`）已合入 MCP；FEED-3（客户端事件流入）待门禁

---

# 0. 为什么现在先出设计

FEED-4 的 Core 聚合已在 MCP 落地，剩余受门禁限制的是报告完整性与真实数据验证：

```text
1. FEED-1 / FEED-2 已合入 MCP（feed_impressions / feed_feedbacks 表已存在）
2. FEED-3 客户端尚未开始上报事件（依赖 UX-7 合入）
3. 即使建好聚合，也没有真实曝光数据可聚合
```

但 FEED-4 的**设计**与 FEED-0 一样是纯分析工作，不受门禁限制。
本文档把 schema、六项指标 SQL、TTL 布线全部定死，门禁一开即可直接实现。

---

# 1. 数据来源（现有表 + FEED-1/2 新表）

| 表 | 来源 | 用途 |
| --- | --- | --- |
| `feed_impressions` | FEED-2 | 曝光 / 打开 / 停留，唯一 user+session+kind+post |
| `feed_feedbacks` | FEED-1 | `not_interested`（含 Source） |
| `user_hidden_authors` | FEED-1 | `hide_author` |
| `likes` | 已有 | interaction density 分子之一 |
| `replies` | 已有 | interaction density 分子之一 |
| `poll_ballots` | 已有 | interaction density 分子之一（投票） |

---

# 2. feed_daily_metrics schema（新增表）

```go
type FeedDailyMetrics struct {
    ID uint `gorm:"primaryKey"`

    Date             time.Time `gorm:"not null;uniqueIndex:idx_feed_daily_metrics"` // 仅日期（YYYY-MM-DD）
    FeedKind         string    `gorm:"not null;uniqueIndex:idx_feed_daily_metrics;size:16"`
    AlgorithmVersion string    `gorm:"not null;uniqueIndex:idx_feed_daily_metrics;size:32"`

    // 曝光
    Impressions    int   `gorm:"not null;default:0"`
    UniqueOpens    int   `gorm:"not null;default:0"`
    SumDwellMS     int64 `gorm:"not null;default:0"`
    SumVisibleMS   int64 `gorm:"not null;default:0"`

    // 负反馈
    NotInterested int `gorm:"not null;default:0"`
    HiddenAuthors int `gorm:"not null;default:0"`

    // 互动
    Likes     int `gorm:"not null;default:0"`
    Replies   int `gorm:"not null;default:0"`
    PollVotes int `gorm:"not null;default:0"`

    CreatedAt time.Time
    UpdatedAt time.Time
}
```

唯一：`date + feed_kind + algorithm_version`。

`AlgorithmVersion` 来自 FEED-2 事件上报的 `algorithm_version`（如 `home_all_v3_poll`）。
按日粒度聚合，长期保留，不参与 30 天 TTL。

---

# 3. 六项指标定义（FEED-4 验收基线）

全部按 `feed_kind` 分别统计：`all / time / featured / following`。

### 3.1 CTR

```text
CTR = unique_opens / valid_impressions
```

- `unique_opens`：`feed_impressions.opened_at IS NOT NULL` 的行数（幂等保证不重复计数）。
- `valid_impressions`：`visible_ms >= 700` 的曝光行数（与 FEED-3 客户端曝光定义一致：≥50% 可见且连续 ≥700ms）。

SQL 草图（每日聚合时计算，存 `feed_daily_metrics`）：

```sql
SELECT
  feed_kind,
  COUNT(*) FILTER (WHERE visible_ms >= 700)             AS valid_impressions,
  COUNT(*) FILTER (WHERE opened_at IS NOT NULL)         AS unique_opens
FROM feed_impressions
WHERE created_at >= :day_start AND created_at < :day_end
GROUP BY feed_kind;
```

> 注：SQLite 无 `FILTER`，聚合实现建议在 Go 侧读行计算，避免方言分叉。

### 3.2 Interaction density

```text
interaction_density = (likes + replies + poll_votes) / impressions × 1000
```

- `likes` / `replies`：当日 `likes` / `replies` 表新增行数（`created_at` 当日）。
- `poll_votes`：当日 `poll_ballots` 新增行数。
- `impressions`：当日有效曝光数（同上）。

### 3.3 Negative feedback

```text
negative_rate = (not_interested + hide_author) / impressions × 1000
```

- `not_interested`：当日 `feed_feedbacks.action='not_interested'` 新增数（含 Source 维度，可按 tab 拆）。
- `hide_author`：当日 `user_hidden_authors` 新增数。

### 3.4 多样性（前 20）

```text
distinct_author   = COUNT(DISTINCT author_id)  IN 排名前 20
distinct_section  = COUNT(DISTINCT post_type)  IN 排名前 20
```

数据源：当日 Snapshot 实际下发顺序（FEED-2 事件带 `position`，取 `position < 20` 的行按 `position` 排序，统计去重）。

### 3.5 新帖公平性

```text
new_post_fairness = 发布后 24h 内达到 20 次有效曝光的帖子数 / 当日发布帖子总数
```

数据源：`feed_impressions`（按 post 聚合）+ `posts.created_at`。

### 3.6 冷启动

```text
cold_start_ctr = 注册后前 3 个 FeedSession 的 综合 CTR
```

数据源：`feed_impressions` 按 `feed_session_id` 排序取前 3 个 session，`feed_kind = 'all'`。
对照基线：P1 上线后此指标不能变差。

---

# 4. TTL 与聚合布线

```text
每日 cron（凌晨，建议 UTC+8 00:10）：
  1. 读取昨日 00:00 ~ 24:00 的 feed_impressions / feed_feedbacks / user_hidden_authors
     + 当日 likes / replies / poll_ballots / posts
  2. 按 (date, feed_kind, algorithm_version) upsert 进 feed_daily_metrics
  3. 调用 FEED-2 已备好的 CleanupExpired(now - 30天)
     → 删除 30 天前的 feed_impressions 明细
```

- `feed_daily_metrics` 长期保留（不删）。
- `feed_impressions` 只留 30 天原始明细。
- 聚合 cron 复用 `internal/tasks` 现有模式（`StartXxxCron` + wg + ticker，参考 `cron.go`）。
- `CleanupExpired` 已在 FEED-2 实现并通过单测，直接复用。

---

# 5. 实现清单（门禁一开按此执行）

| 步骤 | 内容 |
| --- | --- |
| 1 | `models/feed_daily_metrics.go`（上表 schema） |
| 2 | `services/feed_metrics_service.go`：`AggregateDay(ctx, day)` + 六项指标查询方法 |
| 3 | `internal/tasks`：`StartFeedMetricsCron`（每日聚合 + TTL） |
| 4 | `cmd/main.go`：AutoMigrate 注册 + cron 注册 |
| 5 | 单测：聚合幂等（同一天重复跑不翻倍）、TTL 删除、六项指标口径 |
| 6 | `server/API.md`：如需要 `GET /api/admin/feed/metrics`（管理端），P1 前先内部看板 |

---

# 6. 门禁状态

```text
FEED-4 实现条件：
  [x] FEED-1 合入 MCP（feed_feedbacks / user_hidden_authors 表）—— 已合入
  [x] FEED-2 合入 MCP（feed_impressions 表）—— 已合入
  [x] Core 每日聚合 + 30 天 TTL —— 已实现（FEED-4 Core）
  [x] FEED-H1 口径修正（CTR 分母 / Asia/Shanghai 时区 / interaction density scope）—— 已落地
  [ ] FEED-3 客户端开始上报事件（依赖 UX-7 合入）
  [ ] 至少积累数日真实曝光数据

当前：Core 已实现；报告完整性与真实数据验证等待 FEED-3 事件流入。
```
