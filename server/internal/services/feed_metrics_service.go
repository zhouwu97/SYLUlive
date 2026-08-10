package services

import (
	"context"
	"strconv"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

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

// AggregateDay 聚合指定日期的指标并 upsert 进 feed_daily_metrics（幂等）。
// 同一天重复聚合不会翻倍：数值取当日聚合结果整体覆盖。
// 同时清理 30 天前的 feed_impressions 明细（TTL）。
func (s *FeedMetricsService) AggregateDay(ctx context.Context, day time.Time) error {
	dayStart := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.Local)
	dayEnd := dayStart.Add(24 * time.Hour)

	// 1. 曝光聚合：按 (feed_kind, algorithm_version) 分组。
	type impressionAgg struct {
		Impressions int
		UniqueOpens int
		SumDwellMS  int64
		SumVisible  int64
	}
	var impressions []models.FeedImpression
	if err := s.db.WithContext(ctx).
		Where("created_at >= ? AND created_at < ?", dayStart, dayEnd).
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
		if imp.VisibleMS >= 700 { // 有效曝光：≥50% 可见且连续 ≥700ms（FEED-3 客户端口径）
			agg.Impressions++
			agg.SumDwellMS += int64(imp.DwellMS)
			agg.SumVisible += int64(imp.VisibleMS)
		}
		if imp.OpenedAt != nil {
			agg.UniqueOpens++
		}
	}

	// 2. 负反馈：not_interested 按 Source(feed_kind) 分组；hidden_authors 全局计数。
	type feedbackAgg struct{ Count int }
	notInterestedByKind := map[string]int{}
	var feedbacks []models.FeedFeedback
	if err := s.db.WithContext(ctx).
		Where("action = ? AND created_at >= ? AND created_at < ?", models.FeedFeedbackActionNotInterested, dayStart, dayEnd).
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
		Where("created_at >= ? AND created_at < ?", dayStart, dayEnd).
		Count(&hiddenAuthors).Error; err != nil {
		return err
	}

	// 3. 互动：全局当日计数。
	var likes, replies, pollVotes int64
	if err := s.db.WithContext(ctx).Model(&models.Like{}).
		Where("target_type = ? AND created_at >= ? AND created_at < ?", "post", dayStart, dayEnd).
		Count(&likes).Error; err != nil {
		return err
	}
	if err := s.db.WithContext(ctx).Model(&models.Reply{}).
		Where("status = ? AND created_at >= ? AND created_at < ?", models.ReplyStatusNormal, dayStart, dayEnd).
		Count(&replies).Error; err != nil {
		return err
	}
	if err := s.db.WithContext(ctx).Model(&models.PollBallot{}).
		Where("created_at >= ? AND created_at < ?", dayStart, dayEnd).
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

// AggregateAndCleanup 执行聚合后清理 30 天前的曝光明细。
// 返回删除的明细条数。
func (s *FeedMetricsService) AggregateAndCleanup(ctx context.Context, day time.Time, ttl time.Duration) (int64, error) {
	if err := s.AggregateDay(ctx, day); err != nil {
		return 0, err
	}
	eventSvc := NewFeedEventService(s.db)
	return eventSvc.CleanupExpired(ctx, time.Now().Add(-ttl))
}

// MetricReport 单日指标摘要（FEED-4 基线看板数据源）。
type MetricReport struct {
	Date    string `json:"date"`
	Kind    string `json:"feed_kind"`
	CTR     string `json:"ctr"`                 // unique_opens / impressions
	Density string `json:"interaction_density"` // (likes+replies+poll_votes)/impressions ×1000
	NegRate string `json:"negative_rate"`       // (not_interested+hidden)/impressions ×1000
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
		density := ""
		if r.Impressions > 0 {
			density = formatFloat(float64(r.Likes+r.Replies+r.PollVotes) / float64(r.Impressions) * 1000)
		}
		negRate := ""
		if r.Impressions > 0 {
			negRate = formatFloat(float64(r.NotInterested+r.HiddenAuthors) / float64(r.Impressions) * 1000)
		}
		reports = append(reports, MetricReport{
			Date:    r.Date.Format("2006-01-02"),
			Kind:    r.FeedKind,
			CTR:     ctr,
			Density: density,
			NegRate: negRate,
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
