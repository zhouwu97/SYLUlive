package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

var feedMetricsHandlerTestDBSeq int64

func newFeedMetricsHandlerTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&feedMetricsHandlerTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:metrics_handler_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.FeedDailyMetrics{}))
	return db
}

func TestAdminFeedMetricsReturnsDailyReport(t *testing.T) {
	db := newFeedMetricsHandlerTestDB(t)
	loc := time.FixedZone("Asia/Shanghai", 8*3600)
	day := time.Date(2026, 8, 10, 0, 0, 0, 0, loc)
	require.NoError(t, db.Create(&models.FeedDailyMetrics{
		Date: day, FeedKind: "all", AlgorithmVersion: "home_all_v3_poll",
		Impressions: 100, UniqueOpens: 20, SumDwellMS: 300000,
		NotInterested: 2, HiddenAuthors: 1, Likes: 10, Replies: 5, PollVotes: 3,
	}).Error)

	h := NewFeedMetricsHandler(db)
	router := gin.New()
	router.GET("/api/admin/feed/metrics", h.AdminMetrics)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet,
		"/api/admin/feed/metrics?from=2026-08-10&to=2026-08-10", nil)
	router.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)

	var body struct {
		Metrics []services.MetricReport `json:"metrics"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Len(t, body.Metrics, 1)
	m := body.Metrics[0]
	require.Equal(t, "all", m.Kind)
	require.Equal(t, "home_all_v3_poll", m.AlgorithmVersion)
	require.Equal(t, 100, m.Impressions)
	require.Equal(t, 20, m.UniqueOpens)
	require.Equal(t, "20.0%", m.CTR)
	require.Equal(t, 3000, m.AvgDwellMS, "avg_dwell = sum_dwell / impressions")
	require.Equal(t, "global_proxy", m.InteractionDensityScope)
	require.Equal(t, 1, m.HiddenAuthorGlobalCount)
	require.NotEmpty(t, m.NegativeRate)
}

func TestAdminFeedMetricsFeedKindFilter(t *testing.T) {
	db := newFeedMetricsHandlerTestDB(t)
	loc := time.FixedZone("Asia/Shanghai", 8*3600)
	day := time.Date(2026, 8, 10, 0, 0, 0, 0, loc)
	require.NoError(t, db.Create(&models.FeedDailyMetrics{
		Date: day, FeedKind: "all", AlgorithmVersion: "home_all_v3_poll",
		Impressions: 10, UniqueOpens: 1,
	}).Error)
	require.NoError(t, db.Create(&models.FeedDailyMetrics{
		Date: day, FeedKind: "time", AlgorithmVersion: "home_time_v3_poll",
		Impressions: 20, UniqueOpens: 2,
	}).Error)

	h := NewFeedMetricsHandler(db)
	router := gin.New()
	router.GET("/api/admin/feed/metrics", h.AdminMetrics)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet,
		"/api/admin/feed/metrics?from=2026-08-10&to=2026-08-10&feed_kind=time", nil)
	router.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)

	var body struct {
		Metrics []services.MetricReport `json:"metrics"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Len(t, body.Metrics, 1)
	require.Equal(t, "time", body.Metrics[0].Kind)
}
