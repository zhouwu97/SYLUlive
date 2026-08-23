package handlers

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

func newInternalMCPV5TestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:internal-mcp-v5?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AcademicSnapshot{}, &models.UserCalendarEvent{}, &models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{}))
	return db
}

func TestInternalMCPV5AcademicSummaryUsesGrantSubjectNotRequestBody(t *testing.T) {
	db := newInternalMCPV5TestDB(t)
	now := time.Now()
	require.NoError(t, db.Create(&models.AcademicSnapshot{UserID: 7, DatasetType: "grades", PayloadJSON: datatypes.JSON([]byte(`{"grades":[]}`)), PayloadHash: "test", FetchedAt: now, ExpiresAt: now.Add(time.Hour)}).Error)
	manager := ai.NewScopedGrantManager(func() time.Time { return now })
	token, _, err := manager.IssueRunGrant("run-7", 7, []string{"academic.summary"}, []string{"academic:summary"}, time.Minute, 2)
	require.NoError(t, err)
	handler := NewInternalMCPV5Handler(db)
	router := gin.New()
	group := router.Group("/internal/mcp")
	group.Use(InternalMCPGrantOrScopedGrantMiddleware("", manager))
	group.POST("/academic/summary", handler.AcademicSummary)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/internal/mcp/academic/summary", bytes.NewReader([]byte(`{"datasets":["grades"]}`)))
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, request)
	require.Equal(t, http.StatusOK, recorder.Code)
	require.Contains(t, recorder.Body.String(), `"ok":true`)
	require.NotContains(t, recorder.Body.String(), `"user_id"`)
}

func TestInternalMCPV5GrantCannotCallAnotherCapability(t *testing.T) {
	db := newInternalMCPV5TestDB(t)
	manager := ai.NewScopedGrantManager(time.Now)
	token, _, err := manager.IssueRunGrant("run-1", 7, []string{"academic.summary"}, []string{"academic:summary"}, time.Minute, 2)
	require.NoError(t, err)
	router := gin.New()
	router.Use(InternalMCPGrantOrScopedGrantMiddleware("", manager))
	router.POST("/internal/mcp/schedule/free-windows", NewInternalMCPV5Handler(db).ScheduleFreeWindows)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/internal/mcp/schedule/free-windows", bytes.NewReader([]byte(`{"from":"2026-08-23T09:00:00+08:00","to":"2026-08-23T12:00:00+08:00","duration_minutes":30}`)))
	request.Header.Set("Authorization", "Bearer "+token)
	router.ServeHTTP(recorder, request)
	require.Equal(t, http.StatusUnauthorized, recorder.Code)
}
