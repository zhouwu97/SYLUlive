package services

import (
	"context"
	"log"
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
	eventSvc := NewFeedEventService(s.db)
	return eventSvc.CleanupExpired(ctx, time.Now().Add(-ttl))
}

// MetricReport 单日指标摘要（FEED-4 基线看板数据源）。
type MetricReport struct {
	Date string `json:"date"`
	Kind string `json:"feed_kind"`
	CTR  string `json:"ctr"` // unique_opens / impressions
	// 互动密度：仅 all 行有全局互动代理值；其它 feed_kind 无法按 Tab 归因 → null。
	InteractionDensity      *string `json:"interaction_density"`
	InteractionDensityScope string  `json:"interaction_density_scope"` // global_proxy | unavailable
	// 负反馈：not_interested 可按 Source 归因；hidden_author 无 Source，只有全局计数。
	NotInterestedRate       string `json:"not_interested_rate"`
	HiddenAuthorGlobalCount int    `json:"hidden_author_global_count"`
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
		if r.Impressions > 0 {
			notInterestedRate = formatFloat(float64(r.NotInterested) / float64(r.Impressions) * 1000)
		}
		reports = append(reports, MetricReport{
			Date:                    r.Date.Format("2006-01-02"),
			Kind:                    r.FeedKind,
			CTR:                     ctr,
			InteractionDensity:      density,
			InteractionDensityScope: scope,
			NotInterestedRate:       notInterestedRate,
			HiddenAuthorGlobalCount: r.HiddenAuthors,
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
