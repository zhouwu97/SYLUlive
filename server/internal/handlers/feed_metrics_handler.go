package handlers

import (
	"context"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// FeedMetricsHandler 管理端 Feed 指标（FEED-4B）。
type FeedMetricsHandler struct {
	db      *gorm.DB
	metrics *services.FeedMetricsService
}

func NewFeedMetricsHandler(db *gorm.DB) *FeedMetricsHandler {
	return &FeedMetricsHandler{db: db, metrics: services.NewFeedMetricsService(db)}
}

func metricsShanghaiLoc() *time.Location {
	if academiccalendar.ShanghaiLocation != nil {
		return academiccalendar.ShanghaiLocation
	}
	return time.FixedZone("Asia/Shanghai", 8*3600)
}

// AdminMetrics  GET /api/admin/feed/metrics?from=YYYY-MM-DD&to=YYYY-MM-DD&feed_kind=all
//
// 返回按 (date, feed_kind, algorithm_version) 的每日指标；feed_kind 可选过滤。
// 默认最近 7 个上海自然日。
func (h *FeedMetricsHandler) AdminMetrics(c *gin.Context) {
	loc := metricsShanghaiLoc()
	now := time.Now().In(loc)

	dayStart, err := metricsParseDay(c.Query("from"), now.AddDate(0, 0, -6), loc)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	dayEnd, err := metricsParseDay(c.Query("to"), now, loc)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if !dayEnd.After(dayStart) {
		dayEnd = dayStart.AddDate(0, 0, 1)
	}
	// 含 to 当天。
	dayEnd = dayEnd.AddDate(0, 0, 1)

	reports, err := h.metrics.BuildReport(context.Background(), dayStart, dayEnd)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 Feed 指标失败"})
		return
	}

	kind := c.Query("feed_kind")
	if kind != "" {
		if !models.IsValidFeedKind(kind) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的 feed_kind"})
			return
		}
		filtered := reports[:0]
		for _, r := range reports {
			if r.Kind == kind {
				filtered = append(filtered, r)
			}
		}
		reports = filtered
	}
	if reports == nil {
		reports = []services.MetricReport{}
	}
	c.JSON(http.StatusOK, gin.H{"metrics": reports})
}

// metricsParseDay 把 YYYY-MM-DD 解析为上海自然日 00:00；空值用 fallback。
func metricsParseDay(value string, fallback time.Time, loc *time.Location) (time.Time, error) {
	if value == "" {
		return time.Date(fallback.Year(), fallback.Month(), fallback.Day(), 0, 0, 0, 0, loc), nil
	}
	t, err := time.ParseInLocation("2006-01-02", value, loc)
	if err != nil {
		return time.Time{}, err
	}
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, loc), nil
}

// AdminBaseline  GET /api/admin/feed/metrics/baseline?date=YYYY-MM-DD
//
// 返回某上海自然日的补充基线指标（多样性 / 新帖公平性 / 冷启动）。默认昨天。
func (h *FeedMetricsHandler) AdminBaseline(c *gin.Context) {
	loc := metricsShanghaiLoc()
	now := time.Now().In(loc)
	day, err := metricsParseDay(c.Query("date"), now.AddDate(0, 0, -1), loc)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	baseline, err := h.metrics.BaselineOverview(context.Background(), day)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "计算 Feed 基线指标失败"})
		return
	}
	c.JSON(http.StatusOK, baseline)
}
