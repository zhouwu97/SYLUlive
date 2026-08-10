package services

import (
	"context"
	"fmt"
	"log"
	"sort"
	"strconv"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
)

// FeedMetricsService 按日聚合 Feed 指标（FEED-4）。
//
// 聚合在 Go 侧计算（不依赖 SQL 方言 FILTER 等），
// 保证 PostgreSQL / SQLite（单测）两端一致。
type FeedMetricsService struct {
	db *gorm.DB
}

func NewFeedMetricsService(db *gorm.DB) *FeedMetricsService {
	return &FeedMetricsService{db: db}
}

// shanghaiLocation 返回 Asia/Shanghai 时区：优先复用统一 academiccalendar 时区，
// 未初始化时用固定 UTC+8 兜底（Asia/Shanghai 无夏令时）。
func shanghaiLocation() *time.Location {
	if academiccalendar.ShanghaiLocation != nil {
		return academiccalendar.ShanghaiLocation
	}
	return time.FixedZone("Asia/Shanghai", 8*3600)
}

// AggregateDay 聚合指定日期的指标并 upsert 进 feed_daily_metrics（幂等）。
// 同一天重复聚合不会翻倍：数值取当日聚合结果整体覆盖。
// 同时清理 30 天前的 feed_impressions 明细（TTL）。
func (s *FeedMetricsService) AggregateDay(ctx context.Context, day time.Time) error {
	// H1.7：业务日固定按 Asia/Shanghai 自然日计算，不隐式依赖服务器 OS 时区。
	loc := shanghaiLocation()
	sh := day.In(loc)
	dayStart := time.Date(sh.Year(), sh.Month(), sh.Day(), 0, 0, 0, 0, loc)
	dayEnd := dayStart.AddDate(0, 0, 1)
	// 数据库里 created_at 是绝对时刻；查询边界统一用 UTC 表示，避免时区串扰。
	dayStartUTC := dayStart.UTC()
	dayEndUTC := dayEnd.UTC()

	// 1. 曝光聚合：按 (feed_kind, algorithm_version) 分组。
	type impressionAgg struct {
		Impressions int
		UniqueOpens int
		SumDwellMS  int64
		SumVisible  int64
	}
	var impressions []models.FeedImpression
	if err := s.db.WithContext(ctx).
		Where("created_at >= ? AND created_at < ?", dayStartUTC, dayEndUTC).
		Find(&impressions).Error; err != nil {
		return err
	}
	impByKind := map[string]map[string]*impressionAgg{} // feed_kind -> algorithm_version -> agg
	for _, imp := range impressions {
		kindAgg, ok := impByKind[imp.FeedKind]
		if !ok {
			kindAgg = map[string]*impressionAgg{}
			impByKind[imp.FeedKind] = kindAgg
		}
		agg, ok := kindAgg[imp.AlgorithmVersion]
		if !ok {
			agg = &impressionAgg{}
			kindAgg[imp.AlgorithmVersion] = agg
		}
		// H1.6：CTR 分母必须是有效曝光；open 只计入有效曝光记录，避免 CTR>100%。
		if imp.VisibleMS >= 700 { // 有效曝光：≥50% 可见且连续 ≥700ms（FEED-3 客户端口径）
			agg.Impressions++
			agg.SumDwellMS += int64(imp.DwellMS)
			agg.SumVisible += int64(imp.VisibleMS)
			if imp.OpenedAt != nil {
				agg.UniqueOpens++
			}
		}
	}

	// 2. 负反馈：not_interested 按 Source(feed_kind) 分组；hidden_authors 全局计数。
	type feedbackAgg struct{ Count int }
	notInterestedByKind := map[string]int{}
	var feedbacks []models.FeedFeedback
	if err := s.db.WithContext(ctx).
		Where("action = ? AND created_at >= ? AND created_at < ?", models.FeedFeedbackActionNotInterested, dayStartUTC, dayEndUTC).
		Find(&feedbacks).Error; err != nil {
		return err
	}
	for _, fb := range feedbacks {
		source := fb.Source
		if source == "" {
			source = "all"
		}
		notInterestedByKind[source]++
	}

	var hiddenAuthors int64
	if err := s.db.WithContext(ctx).
		Model(&models.UserHiddenAuthor{}).
		Where("created_at >= ? AND created_at < ?", dayStartUTC, dayEndUTC).
		Count(&hiddenAuthors).Error; err != nil {
		return err
	}

	// 3. 互动：全局当日计数。
	var likes, replies, pollVotes int64
	if err := s.db.WithContext(ctx).Model(&models.Like{}).
		Where("target_type = ? AND created_at >= ? AND created_at < ?", "post", dayStartUTC, dayEndUTC).
		Count(&likes).Error; err != nil {
		return err
	}
	if err := s.db.WithContext(ctx).Model(&models.Reply{}).
		Where("status = ? AND created_at >= ? AND created_at < ?", models.ReplyStatusNormal, dayStartUTC, dayEndUTC).
		Count(&replies).Error; err != nil {
		return err
	}
	if err := s.db.WithContext(ctx).Model(&models.PollBallot{}).
		Where("created_at >= ? AND created_at < ?", dayStartUTC, dayEndUTC).
		Count(&pollVotes).Error; err != nil {
		return err
	}

	// 4. 写入 feed_daily_metrics（按 feed_kind 生成行；全局计数归入 all 行）。
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		// 没有曝光数据时也保留 all 基线行（likes/replies/负反馈仍可参考）。
		kinds := map[string]bool{}
		for kind := range impByKind {
			kinds[kind] = true
		}
		if _, ok := kinds["all"]; !ok && (likes > 0 || replies > 0 || pollVotes > 0 || hiddenAuthors > 0 || len(notInterestedByKind) > 0) {
			kinds["all"] = true
		}
		for kind := range kinds {
			verAggs := impByKind[kind]
			if len(verAggs) == 0 {
				verAggs = map[string]*impressionAgg{"": {}}
			}
			for version, agg := range verAggs {
				row := models.FeedDailyMetrics{
					Date:             dayStart,
					FeedKind:         kind,
					AlgorithmVersion: version,
					Impressions:      agg.Impressions,
					UniqueOpens:      agg.UniqueOpens,
					SumDwellMS:       agg.SumDwellMS,
					SumVisibleMS:     agg.SumVisible,
					NotInterested:    notInterestedByKind[kind],
				}
				if kind == "all" {
					row.HiddenAuthors = int(hiddenAuthors)
					row.Likes = int(likes)
					row.Replies = int(replies)
					row.PollVotes = int(pollVotes)
				}
				if err := tx.Clauses(clause.OnConflict{
					Columns: []clause.Column{{Name: "date"}, {Name: "feed_kind"}, {Name: "algorithm_version"}},
					DoUpdates: clause.Assignments(map[string]interface{}{
						"impressions":    row.Impressions,
						"unique_opens":   row.UniqueOpens,
						"sum_dwell_ms":   row.SumDwellMS,
						"sum_visible_ms": row.SumVisibleMS,
						"not_interested": row.NotInterested,
						"hidden_authors": row.HiddenAuthors,
						"likes":          row.Likes,
						"replies":        row.Replies,
						"poll_votes":     row.PollVotes,
						"updated_at":     time.Now(),
					}),
				}).Create(&row).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})
}

// AggregateAndCleanup 执行聚合后清理 30 天前的曝光明细，并顺带清理过期的
// not_interested 反馈（H1.4，失败不阻断主流程）。返回删除的明细条数。
func (s *FeedMetricsService) AggregateAndCleanup(ctx context.Context, day time.Time, ttl time.Duration) (int64, error) {
	if err := s.AggregateDay(ctx, day); err != nil {
		return 0, err
	}
	// H1.4：随现有聚合周期低成本清理过期 not_interested；历史 NULL 视为永久有效。
	visSvc := NewFeedVisibilityService(s.db)
	if _, err := visSvc.CleanupExpiredFeedbacks(ctx, time.Now()); err != nil {
		log.Printf("清理过期 Feed 反馈失败: %v", err)
	}
	// FEED-5：排序追踪 30 天 TTL（失败不阻断主流程）。
	if err := s.db.WithContext(ctx).
		Where("created_at < ?", time.Now().Add(-ttl)).
		Delete(&models.FeedRankTrace{}).Error; err != nil {
		log.Printf("清理 Feed 排序追踪失败: %v", err)
	}
	eventSvc := NewFeedEventService(s.db)
	return eventSvc.CleanupExpired(ctx, time.Now().Add(-ttl))
}

// MetricReport 单日指标摘要（FEED-4 基线看板数据源）。
type MetricReport struct {
	Date string `json:"date"`
	Kind string `json:"feed_kind"`

	// 曝光 / 打开（FEED-4B 管理看板原始口径）。
	AlgorithmVersion string `json:"algorithm_version"`
	Impressions      int    `json:"impressions"`
	UniqueOpens      int    `json:"unique_opens"`

	CTR        string `json:"ctr"`          // unique_opens / impressions
	AvgDwellMS int    `json:"avg_dwell_ms"` // sum_dwell / impressions

	// 互动密度：仅 all 行有全局互动代理值；其它 feed_kind 无法按 Tab 归因 → null。
	InteractionDensity      *string `json:"interaction_density"`
	InteractionDensityScope string  `json:"interaction_density_scope"` // global_proxy | unavailable
	// 负反馈：not_interested 可按 Source 归因；hidden_author 无 Source，只有全局计数。
	NotInterestedRate       string `json:"not_interested_rate"`
	HiddenAuthorGlobalCount int    `json:"hidden_author_global_count"`
	// 综合负反馈率（not_interested + hidden）/ impressions ×1000。
	NegativeRate string `json:"negative_rate"`
}

// BuildReport 读取 feed_daily_metrics 生成基线报告（仅含曝光 > 0 的行）。
func (s *FeedMetricsService) BuildReport(ctx context.Context, dayStart, dayEnd time.Time) ([]MetricReport, error) {
	var rows []models.FeedDailyMetrics
	if err := s.db.WithContext(ctx).
		Where("date >= ? AND date < ? AND impressions > 0", dayStart, dayEnd).
		Order("date ASC").Order("feed_kind ASC").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	reports := make([]MetricReport, 0, len(rows))
	for _, r := range rows {
		ctr := ""
		if r.Impressions > 0 {
			ctr = formatPercent(float64(r.UniqueOpens) / float64(r.Impressions) * 100)
		}
		var density *string
		scope := "unavailable"
		if r.FeedKind == "all" && r.Impressions > 0 {
			v := formatFloat(float64(r.Likes+r.Replies+r.PollVotes) / float64(r.Impressions) * 1000)
			density = &v
			scope = "global_proxy"
		}
		notInterestedRate := ""
		negRate := ""
		avgDwell := 0
		if r.Impressions > 0 {
			notInterestedRate = formatFloat(float64(r.NotInterested) / float64(r.Impressions) * 1000)
			negRate = formatFloat(float64(r.NotInterested+r.HiddenAuthors) / float64(r.Impressions) * 1000)
			if r.SumDwellMS > 0 {
				avgDwell = int(r.SumDwellMS / int64(r.Impressions))
			}
		}
		reports = append(reports, MetricReport{
			Date:                    r.Date.Format("2006-01-02"),
			Kind:                    r.FeedKind,
			AlgorithmVersion:        r.AlgorithmVersion,
			Impressions:             r.Impressions,
			UniqueOpens:             r.UniqueOpens,
			CTR:                     ctr,
			AvgDwellMS:              avgDwell,
			InteractionDensity:      density,
			InteractionDensityScope: scope,
			NotInterestedRate:       notInterestedRate,
			HiddenAuthorGlobalCount: r.HiddenAuthors,
			NegativeRate:            negRate,
		})
	}
	return reports, nil
}

// 格式化辅助：保持精简，数值直接用 strconv。
func formatPercent(v float64) string {
	return strconv.FormatFloat(v, 'f', 1, 64) + "%"
}

func formatFloat(v float64) string {
	return strconv.FormatFloat(v, 'f', 2, 64)
}

// BaselineMetrics 某日的补充基线指标（FEED-4B §26.2-26.4）。
type BaselineMetrics struct {
	Date string `json:"date"`
	// 第一屏多样性：当日 top-20 位置去重作者 / 版块数。
	Top20DistinctAuthors  int `json:"top20_distinct_authors"`
	Top20DistinctSections int `json:"top20_distinct_sections"`
	// 新帖公平性：当日发布帖子中，24h 内获得 ≥20 次有效曝光的比例（%）。
	NewPostFairnessPercent string `json:"new_post_fairness_percent"`
	// 冷启动：注册后前 3 个 session 的「综合」CTR（%）。
	ColdStartCTR string `json:"cold_start_ctr"`
}

// BaselineOverview 统计某上海自然日的补充基线指标。
func (s *FeedMetricsService) BaselineOverview(ctx context.Context, day time.Time) (BaselineMetrics, error) {
	loc := shanghaiLocation()
	sh := day.In(loc)
	dayStart := time.Date(sh.Year(), sh.Month(), sh.Day(), 0, 0, 0, 0, loc).UTC()
	dayEnd := dayStart.AddDate(0, 0, 1)
	out := BaselineMetrics{Date: day.In(loc).Format("2006-01-02")}

	// 1. 第一屏多样性：position 0..19 的去重作者 / 版块。
	var topImps []models.FeedImpression
	if err := s.db.WithContext(ctx).
		Where("position >= 0 AND position < 20 AND created_at >= ? AND created_at < ?", dayStart, dayEnd).
		Find(&topImps).Error; err != nil {
		return out, err
	}
	postIDs := map[uint]struct{}{}
	for _, imp := range topImps {
		postIDs[imp.PostID] = struct{}{}
	}
	if len(postIDs) > 0 {
		ids := make([]uint, 0, len(postIDs))
		for id := range postIDs {
			ids = append(ids, id)
		}
		var rows []struct {
			AuthorID uint
			PostType string
		}
		if err := s.db.WithContext(ctx).Model(&models.Post{}).
			Select("author_id, post_type").
			Where("id IN ?", ids).
			Scan(&rows).Error; err != nil {
			return out, err
		}
		authors := map[uint]struct{}{}
		sections := map[string]struct{}{}
		for _, row := range rows {
			authors[row.AuthorID] = struct{}{}
			if row.PostType != "" {
				sections[row.PostType] = struct{}{}
			}
		}
		out.Top20DistinctAuthors = len(authors)
		out.Top20DistinctSections = len(sections)
	}

	// 2. 新帖公平性：当日发布帖子 24h 内有效曝光（visible_ms>=700）≥20。
	var dayPosts []models.Post
	if err := s.db.WithContext(ctx).
		Where("status = ? AND created_at >= ? AND created_at < ?", models.PostStatusNormal, dayStart, dayEnd).
		Find(&dayPosts).Error; err != nil {
		return out, err
	}
	if len(dayPosts) > 0 {
		postIDs := make([]uint, 0, len(dayPosts))
		byID := map[uint]models.Post{}
		for _, p := range dayPosts {
			postIDs = append(postIDs, p.ID)
			byID[p.ID] = p
		}
		var validImps []models.FeedImpression
		if err := s.db.WithContext(ctx).
			Where("post_id IN ? AND visible_ms >= 700 AND created_at >= ? AND created_at < ?",
				postIDs, dayStart, dayEnd.AddDate(0, 0, 1)).
			Find(&validImps).Error; err != nil {
			return out, err
		}
		counts := map[uint]int{}
		for _, imp := range validImps {
			// 只计发布后 24h 内的有效曝光。
			if imp.CreatedAt.Before(byID[imp.PostID].CreatedAt.Add(24 * time.Hour)) {
				counts[imp.PostID]++
			}
		}
		reached := 0
		for _, count := range counts {
			if count >= 20 {
				reached++
			}
		}
		out.NewPostFairnessPercent = formatPercent(float64(reached) / float64(len(dayPosts)) * 100)
	}

	// 3. 冷启动：注册后前 3 个 session 的「综合」CTR。
	coldStart := s.coldStartCTR(ctx, dayStart, dayEnd)
	out.ColdStartCTR = coldStart

	return out, nil
}

func (s *FeedMetricsService) coldStartCTR(ctx context.Context, dayStart, dayEnd time.Time) string {
	// 读取当日 all 曝光明细，在 Go 侧聚合：每用户最早 3 个 session 的有效曝光 / open。
	var imps []models.FeedImpression
	if err := s.db.WithContext(ctx).
		Where("feed_kind = ? AND created_at >= ? AND created_at < ?", "all", dayStart, dayEnd).
		Find(&imps).Error; err != nil {
		return ""
	}
	if len(imps) == 0 {
		return ""
	}
	// user -> 有序 session 列表（含首次时间）。
	type sessionEntry struct {
		Session   string
		CreatedAt time.Time
	}
	userSessions := map[uint][]sessionEntry{}
	seenSession := map[string]bool{}
	// user+session -> 聚合。
	type sessionCount struct {
		imps  int
		opens int
	}
	counts := map[string]sessionCount{}
	for _, imp := range imps {
		if imp.VisibleMS < 700 {
			continue
		}
		key := fmt.Sprintf("%d|%s", imp.UserID, imp.FeedSessionID)
		c := counts[key]
		c.imps++
		if imp.OpenedAt != nil {
			c.opens++
		}
		counts[key] = c
		if !seenSession[key] {
			seenSession[key] = true
			userSessions[imp.UserID] = append(userSessions[imp.UserID], sessionEntry{
				Session: imp.FeedSessionID, CreatedAt: imp.CreatedAt,
			})
		}
	}
	var totalImp, totalOpen int
	for userID, entries := range userSessions {
		sort.Slice(entries, func(i, j int) bool {
			return entries[i].CreatedAt.Before(entries[j].CreatedAt)
		})
		first := entries
		if len(first) > 3 {
			first = first[:3]
		}
		for _, entry := range first {
			c := counts[fmt.Sprintf("%d|%s", userID, entry.Session)]
			totalImp += c.imps
			totalOpen += c.opens
		}
	}
	if totalImp == 0 {
		return ""
	}
	return formatPercent(float64(totalOpen) / float64(totalImp) * 100)
}
