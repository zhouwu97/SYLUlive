package services

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var metricsTestDBSeq int64

func newMetricsTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&metricsTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:metrics_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.FeedImpression{}, &models.FeedFeedback{}, &models.UserHiddenAuthor{},
		&models.Like{}, &models.Reply{}, &models.PollBallot{}, &models.FeedDailyMetrics{},
	))
	return db
}

type impSpec struct {
	visibleMS int
	dwellMS   int
	opened    bool
	kind      string
	version   string
	createdAt time.Time
}

func insertImpression(t *testing.T, db *gorm.DB, spec impSpec, postID uint) {
	t.Helper()
	createdAt := spec.createdAt.UTC()
	imp := models.FeedImpression{
		UserID: 1, PostID: postID, FeedSessionID: "sess", FeedKind: spec.kind,
		AlgorithmVersion: spec.version, VisibleMS: spec.visibleMS, DwellMS: spec.dwellMS,
		CreatedAt: createdAt,
	}
	if spec.opened {
		openedAt := createdAt.Add(time.Second)
		imp.OpenedAt = &openedAt
	}
	require.NoError(t, db.Create(&imp).Error)
}

func aggregateAndRead(t *testing.T, db *gorm.DB, day time.Time, kind, version string) models.FeedDailyMetrics {
	t.Helper()
	require.NoError(t, NewFeedMetricsService(db).AggregateDay(context.Background(), day))
	var row models.FeedDailyMetrics
	require.NoError(t, db.Where("feed_kind = ? AND algorithm_version = ?", kind, version).First(&row).Error)
	return row
}

func TestMetricsUniqueOpensRequireValidImpression(t *testing.T) {
	db := newMetricsTestDB(t)
	now := time.Now()

	// 无效曝光 + open → 不计入。
	insertImpression(t, db, impSpec{visibleMS: 500, opened: true, kind: "all", version: "v3", createdAt: now}, 1)
	// 有效曝光 + open → 计入。
	insertImpression(t, db, impSpec{visibleMS: 900, opened: true, kind: "all", version: "v3", createdAt: now}, 2)

	row := aggregateAndRead(t, db, now, "all", "v3")
	require.Equal(t, 1, row.Impressions, "只有有效曝光计入")
	require.Equal(t, 1, row.UniqueOpens, "open 只计入有效曝光记录内")
}

func TestMetricsCTRNotAbove100(t *testing.T) {
	db := newMetricsTestDB(t)
	now := time.Now()

	// 2 条有效曝光，1 条 open；另加 1 条无效曝光 + open（不应膨胀分子）。
	insertImpression(t, db, impSpec{visibleMS: 800, opened: true, kind: "all", version: "v3", createdAt: now}, 1)
	insertImpression(t, db, impSpec{visibleMS: 700, opened: false, kind: "all", version: "v3", createdAt: now}, 2)
	insertImpression(t, db, impSpec{visibleMS: 100, opened: true, kind: "all", version: "v3", createdAt: now}, 3)

	row := aggregateAndRead(t, db, now, "all", "v3")
	require.Equal(t, 2, row.Impressions)
	require.Equal(t, 1, row.UniqueOpens)
	require.LessOrEqual(t, float64(row.UniqueOpens)/float64(row.Impressions), 1.0, "CTR 不应 >100%")
}

func TestMetricsDayAggregationIdempotent(t *testing.T) {
	db := newMetricsTestDB(t)
	now := time.Now()
	insertImpression(t, db, impSpec{visibleMS: 800, opened: true, kind: "all", version: "v3", createdAt: now}, 1)

	svc := NewFeedMetricsService(db)
	require.NoError(t, svc.AggregateDay(context.Background(), now))
	require.NoError(t, svc.AggregateDay(context.Background(), now))

	var count int64
	require.NoError(t, db.Model(&models.FeedDailyMetrics{}).Count(&count).Error)
	require.EqualValues(t, 1, count, "同一天重复聚合应幂等，不新增行")

	var row models.FeedDailyMetrics
	require.NoError(t, db.First(&row).Error)
	require.Equal(t, 1, row.Impressions)
	require.Equal(t, 1, row.UniqueOpens)
}

func TestMetricsAsiaShanghaiMidnightBoundary(t *testing.T) {
	db := newMetricsTestDB(t)
	loc := shanghaiLocation()

	// 北京时间 2026-08-10 23:59:59 = UTC 15:59:59 → 属于 08-10 上海日。
	beforeMidnight := time.Date(2026, 8, 10, 15, 59, 59, 0, time.UTC)
	// 北京时间 2026-08-11 00:00:01 = UTC 16:00:01 → 属于 08-11 上海日。
	afterMidnight := time.Date(2026, 8, 10, 16, 0, 1, 0, time.UTC)

	insertImpression(t, db, impSpec{visibleMS: 800, opened: true, kind: "all", version: "v3", createdAt: beforeMidnight}, 1)
	insertImpression(t, db, impSpec{visibleMS: 800, opened: true, kind: "all", version: "v3", createdAt: afterMidnight}, 2)

	day10 := time.Date(2026, 8, 10, 12, 0, 0, 0, loc)
	row10 := aggregateAndRead(t, db, day10, "all", "v3")
	require.Equal(t, 1, row10.Impressions, "08-10 上海日只包含 23:59:59 事件")

	day11 := time.Date(2026, 8, 11, 12, 0, 0, 0, loc)
	row11 := aggregateAndRead(t, db, day11, "all", "v3")
	require.Equal(t, 1, row11.Impressions, "08-11 上海日只包含 00:00:01 事件")
}

func TestMetricsInteractionDensityScope(t *testing.T) {
	db := newMetricsTestDB(t)
	now := time.Now()

	insertImpression(t, db, impSpec{visibleMS: 800, opened: true, kind: "all", version: "home_all_v3_poll", createdAt: now}, 1)
	insertImpression(t, db, impSpec{visibleMS: 800, opened: true, kind: "time", version: "home_time_v3_poll", createdAt: now}, 2)

	svc := NewFeedMetricsService(db)
	require.NoError(t, svc.AggregateDay(context.Background(), now))

	// BuildReport 按上海自然日边界查询。
	loc := shanghaiLocation()
	sh := now.In(loc)
	dayStart := time.Date(sh.Year(), sh.Month(), sh.Day(), 0, 0, 0, 0, loc)
	reports, err := svc.BuildReport(context.Background(), dayStart, dayStart.AddDate(0, 0, 1))
	require.NoError(t, err)

	var allRow, timeRow *MetricReport
	for i := range reports {
		r := &reports[i]
		switch r.Kind {
		case "all":
			allRow = r
		case "time":
			timeRow = r
		}
	}
	require.NotNil(t, allRow, "应有 all 行")
	require.NotNil(t, timeRow, "应有 time 行")

	require.NotNil(t, allRow.InteractionDensity, "all 行有全局互动代理值")
	require.Equal(t, "global_proxy", allRow.InteractionDensityScope)

	require.Nil(t, timeRow.InteractionDensity, "非 all 行不得伪造 density")
	require.Equal(t, "unavailable", timeRow.InteractionDensityScope)
}

func TestEventServiceDwellRemainsMax(t *testing.T) {
	db := newMetricsTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.FeedImpression{}))

	svc := NewFeedEventService(db)
	err := svc.RecordEvents(1, "sess", "all", "v3", []FeedEvent{
		{Type: models.FeedEventImpression, PostID: 1, VisibleMS: 1000},
		{Type: models.FeedEventDwell, PostID: 1, DwellMS: 3000},
	})
	require.NoError(t, err)
	// 第二次上报 dwell 更小 → 保持最大。
	err = svc.RecordEvents(1, "sess", "all", "v3", []FeedEvent{
		{Type: models.FeedEventDwell, PostID: 1, DwellMS: 1000},
	})
	require.NoError(t, err)

	var imp models.FeedImpression
	require.NoError(t, db.First(&imp).Error)
	require.Equal(t, 3000, imp.DwellMS, "dwell 取最大，不累加")
}

func TestBaselineOverviewDiversityAndFairness(t *testing.T) {
	db := newMetricsTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.Post{}))
	loc := shanghaiLocation()
	day := time.Date(2026, 8, 10, 12, 0, 0, 0, loc)
	created := day.UTC().Add(-time.Hour)

	p1 := models.Post{BoardID: models.BoardShuitie, AuthorID: 1, PostType: "course_study", Title: "一", Content: "x", Status: models.PostStatusNormal, CreatedAt: created}
	p2 := models.Post{BoardID: models.BoardShuitie, AuthorID: 2, PostType: "campus_life", Title: "二", Content: "x", Status: models.PostStatusNormal, CreatedAt: created}
	require.NoError(t, db.Create(&p1).Error)
	require.NoError(t, db.Create(&p2).Error)

	now := created
	// p1：20 个 session 各一次有效曝光（position 0），无 open；时间递增保证 session 顺序确定。
	for i := 0; i < 20; i++ {
		require.NoError(t, db.Create(&models.FeedImpression{
			UserID: 1, PostID: p1.ID, FeedSessionID: fmt.Sprintf("s%d", i+1), FeedKind: "all",
			AlgorithmVersion: "v3", Position: 0, VisibleMS: 800,
			CreatedAt: now.Add(time.Second * time.Duration(i)),
		}).Error)
	}
	// p2：1 个 session，position 1，带 open（时间更晚，不在前 3 个 session）。
	openedAt := now.Add(time.Minute)
	require.NoError(t, db.Create(&models.FeedImpression{
		UserID: 1, PostID: p2.ID, FeedSessionID: "s21", FeedKind: "all",
		AlgorithmVersion: "v3", Position: 1, VisibleMS: 800,
		CreatedAt: now.Add(time.Minute), OpenedAt: &openedAt,
	}).Error)

	baseline, err := NewFeedMetricsService(db).BaselineOverview(context.Background(), day)
	require.NoError(t, err)
	require.Equal(t, 2, baseline.Top20DistinctAuthors)
	require.Equal(t, 2, baseline.Top20DistinctSections)
	require.Equal(t, "50.0%", baseline.NewPostFairnessPercent, "p1 达到20次，p2 未达到 → 1/2")
	require.Equal(t, "0.0%", baseline.ColdStartCTR, "前 3 个 session（s1..s3）均无 open")
}
