package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newCheckInHandlerTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{TranslateError: true})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{}, &models.CheckIn{}, &models.UserCheckInStat{}, &models.CheckInRepairLog{},
		&models.CheckInCompensationCampaign{}, &models.CheckInCompensationEligibility{}, &models.CheckInCompensationClaim{},
		&models.UserExperienceLedger{},
	))
	require.NoError(t, models.EnsureCheckInSchema(db))
	return db
}

func TestCheckInHandlerInspectAndRebuildAllStats(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db := newCheckInHandlerTestDB(t)
	handler := NewCheckInHandler(db)

	user := models.User{StudentID: "admin-inspect-test", PasswordHash: "pwd", Nickname: "TestUser", Exp: 10}
	require.NoError(t, db.Create(&user).Error)

	d1 := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	d2 := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	require.NoError(t, db.Create(&models.CheckIn{UserID: user.ID, CheckInDate: d1, StreakDays: 99, ExpEarned: 1}).Error)
	require.NoError(t, db.Create(&models.CheckIn{UserID: user.ID, CheckInDate: d2, StreakDays: 1, ExpEarned: 1}).Error)

	r := gin.New()
	r.Use(func(c *gin.Context) {
		c.Set("user_id", uint(1001))
		c.Next()
	})
	r.GET("/api/admin/checkin/inspect", handler.InspectStats)
	r.POST("/api/admin/checkin/rebuild-all", handler.RebuildAllStats)

	// 1. Inspect
	w1 := httptest.NewRecorder()
	req1, _ := http.NewRequest(http.MethodGet, "/api/admin/checkin/inspect", nil)
	r.ServeHTTP(w1, req1)
	require.Equal(t, http.StatusOK, w1.Code)

	var inspectResp struct {
		Success      bool                          `json:"success"`
		TotalCount   int                           `json:"total_count"`
		Inconsistent []models.CheckInInconsistency `json:"inconsistent"`
	}
	require.NoError(t, json.Unmarshal(w1.Body.Bytes(), &inspectResp))
	require.True(t, inspectResp.Success)
	require.Equal(t, 1, inspectResp.TotalCount)
	require.Equal(t, user.ID, inspectResp.Inconsistent[0].UserID)

	// 2. Rebuild-all
	w2 := httptest.NewRecorder()
	req2, _ := http.NewRequest(http.MethodPost, "/api/admin/checkin/rebuild-all", nil)
	r.ServeHTTP(w2, req2)
	require.Equal(t, http.StatusOK, w2.Code)

	var rebuildResp struct {
		Success           bool `json:"success"`
		InconsistentCount int  `json:"inconsistent_count"`
		RepairedCount     int  `json:"repaired_count"`
	}
	require.NoError(t, json.Unmarshal(w2.Body.Bytes(), &rebuildResp))
	require.True(t, rebuildResp.Success)
	require.Equal(t, 1, rebuildResp.InconsistentCount)
	require.Equal(t, 1, rebuildResp.RepairedCount)

	// 3. Inspect again -> should be empty
	w3 := httptest.NewRecorder()
	req3, _ := http.NewRequest(http.MethodGet, "/api/admin/checkin/inspect", nil)
	r.ServeHTTP(w3, req3)
	require.Equal(t, http.StatusOK, w3.Code)

	var inspectResp2 struct {
		Success    bool `json:"success"`
		TotalCount int  `json:"total_count"`
	}
	require.NoError(t, json.Unmarshal(w3.Body.Bytes(), &inspectResp2))
	require.True(t, inspectResp2.Success)
	require.Equal(t, 0, inspectResp2.TotalCount)
}
