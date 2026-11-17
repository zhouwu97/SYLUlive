package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestSecurityCenterHistoricalLimitsAreAuditInFiltersCountsAndDTO(t *testing.T) {
	h, db := newSecurityAdminTestEnv(t)
	now := time.Now()
	for i, kind := range []string{"login_failed", "login_bruteforce", "email_target_flood", "verification_spray", "password_reset_spray", "verification_source_rate", "search_abuse", " LOGIN_FAILED "} {
		seedSecurityEvent(t, db, fmt.Sprintf("audit-%d", i), kind, models.SecuritySeverityCritical, now)
	}
	seedSecurityEvent(t, db, "review", "login_password_spray", models.SecuritySeverityHigh, now)
	seedSecurityEvent(t, db, "credential", "refresh_token_reused", models.SecuritySeverityCritical, now)
	require.Len(t, listSecurityEventIDs(t, h, "/probe?actionable=true"), 2)
	require.Len(t, listSecurityEventIDs(t, h, "/probe?actionable=false&severity=low"), 8)
	require.Len(t, listSecurityEventIDs(t, h, "/probe?severity=high"), 1)
	require.Len(t, listSecurityEventIDs(t, h, "/probe?severity=critical"), 1)
	r := performSecurityAdminGET(t, h.ListEvents, "/probe?actionable=false")
	var payload struct {
		Items []securityEventResponse `json:"items"`
	}
	require.NoError(t, json.Unmarshal(r.Body.Bytes(), &payload))
	for _, event := range payload.Items {
		require.False(t, event.Actionable)
		require.Equal(t, "low", event.Severity)
	}
	var overview map[string]interface{}
	r = performSecurityAdminGET(t, h.Overview, "/probe?range=24h")
	require.Equal(t, http.StatusOK, r.Code)
	require.NoError(t, json.Unmarshal(r.Body.Bytes(), &overview))
	require.EqualValues(t, 2, overview["active_high_count"])
	require.EqualValues(t, 2, overview["actionable_high_count"])
	require.EqualValues(t, 2, overview["actionable_pending_count"])
	require.EqualValues(t, 1, overview["critical_count"])
	var stored models.SecurityEvent
	require.NoError(t, db.Where("bucket_key = ?", "audit-0").First(&stored).Error)
	require.Equal(t, "critical", stored.Severity, "展示修正不能覆盖原始历史证据")
}

func TestSecurityLoginReviewNeedsRepeatedFailuresAndDoesNotCountCooldownRetries(t *testing.T) {
	h, db := newSecurityAdminTestEnv(t)
	auth := &AuthHandler{db: db, security: h.security}
	ip := "203.0.113.52"
	seed := func(i int) {
		require.NoError(t, h.security.Record(services.SecurityEventInput{EventType: "login_failed", Severity: "low", ClientIP: ip,
			Route: "/api/login", Method: "POST", TargetType: "account", TargetValue: fmt.Sprintf("candidate-%d@example.invalid", i)}))
	}
	for i := 0; i < 20; i++ {
		for range 4 {
			seed(i)
		}
	}
	router := gin.New()
	require.NoError(t, router.SetTrustedProxies(nil))
	outcome := loginFailureOutcome(0)
	router.POST("/probe", func(c *gin.Context) {
		auth.recordLoginSecurityEvent(c, "candidate-0@example.invalid", nil, outcome)
		c.Status(http.StatusNoContent)
	})
	call := func() {
		req := httptest.NewRequest("POST", "/probe", nil)
		req.RemoteAddr = ip + ":1234"
		r := httptest.NewRecorder()
		router.ServeHTTP(r, req)
		require.Equal(t, http.StatusNoContent, r.Code)
	}
	call()
	var count int64
	require.NoError(t, db.Model(&models.SecurityEvent{}).Where("event_type = ?", "login_password_spray").Count(&count).Error)
	require.Zero(t, count, "共享出口多账号少量失败不应直接升级")
	for i := 0; i < 18; i++ {
		seed(i)
	}
	call()
	var review models.SecurityEvent
	require.NoError(t, db.Where("event_type = ?", "login_password_spray").First(&review).Error)
	require.Equal(t, "observed", review.Action, "仅观察到异常模式时不能声称已限流")
	require.Zero(t, review.BlockedCount)
	require.Contains(t, review.MetadataJSON, `"distinct_targets":20`)
	require.Contains(t, review.MetadataJSON, `"failure_count":100`)
	before := review.AttemptCount
	outcome = loginLockedOutcome
	call()
	require.NoError(t, db.First(&review, review.ID).Error)
	require.Equal(t, before, review.AttemptCount, "未比对密码的冷却请求不反复制造待办")
}
