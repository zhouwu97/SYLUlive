package handlers

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestIntegrationManagementHTTPRoleIsolationRestrictionAndNoPrivateBypass(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open("file:"+uuid.NewString()+"?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Discard})
	require.NoError(t, err)
	pool, _ := db.DB()
	pool.SetMaxOpenConns(1)
	t.Cleanup(func() {
		pool.Close()
		for _, id := range []uint{61001, 61002} {
			middleware.InvalidateTokenVersionCache(id)
		}
	})
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AcademicIdentityBinding{}, &models.RefreshToken{}, &models.IntegrationBinding{}, &models.IntegrationCredential{}, &models.IntegrationDeviceRequest{}, &models.IntegrationAction{}, &models.IntegrationAudit{}, &models.IntegrationRateBucket{}, &models.AIUserPermission{}, &models.AcademicSnapshot{}, &models.PersonalUploadedSnapshot{}))
	const secret = "isolated-integration-http"
	appTokens := map[uint]string{}
	for _, id := range []uint{61001, 61002} {
		role := models.RoleUser
		if id == 61002 {
			role = models.RoleAdmin
		}
		require.NoError(t, db.Create(&models.User{ID: id, Nickname: "合成权限用户", Role: role, AccountStatus: "active"}).Error)
		require.NoError(t, db.Create(&models.AcademicIdentityBinding{UserID: id, ProviderID: models.AcademicProviderUndergraduate, StudentID: uuid.NewString(), VerificationMethod: "school_profile", VerificationVersion: "v1", VerifiedAt: time.Now()}).Error)
		for _, doc := range models.RequiredLegalDocuments(false) {
			require.NoError(t, db.Create(&models.UserLegalConsent{UserID: id, Document: doc, Version: models.LegalDocumentVersion, AcceptedAt: time.Now()}).Error)
		}
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		c.Request = httptest.NewRequest("POST", "/api/login", nil)
		_, family, err := issueRefreshSessionForDB(db, id, c)
		require.NoError(t, err)
		token, err := middleware.GenerateToken(id, string(role), 0, secret, family)
		require.NoError(t, err)
		appTokens[id] = token
	}
	h := NewIntegrationHandler(db, IntegrationOptions{PersonalDataEnabled: true})
	r := gin.New()
	h.Register(r, secret)
	send := func(method, path, token, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w
	}
	require.Equal(t, 401, send("GET", "/api/admin/integrations", "", "").Code)
	require.Equal(t, 403, send("GET", "/api/admin/integrations", appTokens[61001], "").Code)
	require.Equal(t, 200, send("GET", "/api/admin/integrations", appTokens[61002], "").Code)
	device, err := h.auth.RequestDevice(context.Background(), uuid.NewString(), "QQ 合成本人 · 共享助手", services.IntegrationGradesScope+" "+services.IntegrationErkeScope)
	require.NoError(t, err)
	consent, err := h.auth.LookupConsent(context.Background(), 61001, device.UserCode)
	require.NoError(t, err)
	binding, err := h.auth.DecideConsent(context.Background(), 61001, consent.ID, services.IntegrationConsentDecision{Allow: true, Scopes: consent.RequestedScopes, Nonce: consent.Nonce})
	require.NoError(t, err)
	h.auth.Now = func() time.Time { return time.Now().Add(10 * time.Second) }
	tokens, err := h.auth.ExchangeDevice(context.Background(), device.DeviceCode)
	require.NoError(t, err)
	require.Equal(t, 401, send("GET", "/api/integrations/v1/me/grades", appTokens[61002], "").Code, "App管理员不能替代本人集成令牌")
	require.Equal(t, 422, send("GET", "/api/integrations/v1/me/grades?user_id=61002", tokens.AccessToken, "").Code)
	require.Equal(t, 409, send("GET", "/api/integrations/v1/me/grades", tokens.AccessToken, "").Code, "未同步不能假装查到数据")
	upload, _ := json.Marshal(map[string]interface{}{"consent": true, "fetched_at": time.Now(), "year": "2026", "semester": 3, "grades": []map[string]interface{}{{"course_name": "本机同步测试课程", "score": "优秀", "credits": 2}}})
	wSync := send("POST", "/api/connected-apps/personal-sync/grades", appTokens[61001], string(upload))
	require.Equal(t, 200, wSync.Code, wSync.Body.String())
	wSync = send("GET", "/api/integrations/v1/me/grades", tokens.AccessToken, "")
	require.Equal(t, 200, wSync.Code, wSync.Body.String())
	require.Contains(t, wSync.Body.String(), "本机同步测试课程")
	require.Contains(t, wSync.Body.String(), `"live_query":false`)
	h.options.PersonalDataEnabled = false
	require.Equal(t, 403, send("GET", "/api/integrations/v1/me/grades", tokens.AccessToken, "").Code, "关闭服务开关后旧凭证也不能读取")
	require.Equal(t, 403, send("POST", "/api/connected-apps/personal-sync/grades", appTokens[61001], string(upload)).Code)
	blockedDevice, err := h.auth.RequestDevice(context.Background(), uuid.NewString(), "合成停用检查", services.IntegrationGradesScope)
	require.NoError(t, err)
	blockedConsent, err := h.auth.LookupConsent(context.Background(), 61002, blockedDevice.UserCode)
	require.NoError(t, err)
	blockedDecision, _ := json.Marshal(map[string]interface{}{"allow": true, "scopes": []string{services.IntegrationGradesScope}, "confirmation_nonce": blockedConsent.Nonce})
	wBlocked := send("POST", "/api/connected-apps/device-requests/"+blockedConsent.ID+"/decision", appTokens[61002], string(blockedDecision))
	require.Equal(t, 403, wBlocked.Code)
	require.Contains(t, wBlocked.Body.String(), "personal_queries_disabled")
	deniedDecision, _ := json.Marshal(map[string]interface{}{"allow": false, "scopes": []string{services.IntegrationGradesScope}, "confirmation_nonce": blockedConsent.Nonce})
	require.Equal(t, 200, send("POST", "/api/connected-apps/device-requests/"+blockedConsent.ID+"/decision", appTokens[61002], string(deniedDecision)).Code, "关闭个人查询仍应允许本人拒绝待授权请求")
	require.Equal(t, 204, send("DELETE", "/api/connected-apps/personal-sync/grades", appTokens[61001], "").Code, "关查询仍保留本人删除权")
	h.options.PersonalDataEnabled = true
	require.Equal(t, 422, send("GET", "/api/integrations/v1/me/erke?offset=2", tokens.AccessToken, "").Code)
	w := send("GET", "/api/admin/integrations", appTokens[61002], "")
	require.Equal(t, 200, w.Code)
	require.Contains(t, w.Body.String(), "合成本人")
	require.NotContains(t, w.Body.String(), "AcademicBindingID")
	require.NotContains(t, w.Body.String(), tokens.AccessToken)
	data, _ := json.Marshal(map[string]interface{}{"expected_epoch": binding.Epoch, "scopes": []string{services.IntegrationGradesScope}, "reason": "合成后台缩减"})
	path := "/api/admin/integrations/" + binding.ID + "/restrict"
	require.Equal(t, 403, send("POST", path, appTokens[61001], string(data)).Code)
	w = send("POST", path, appTokens[61002], string(data))
	require.Equal(t, 200, w.Code, w.Body.String())
	require.Equal(t, 401, send("GET", "/api/integrations/v1/me/grades", tokens.AccessToken, "").Code)
	require.Equal(t, 409, send("POST", path, appTokens[61002], string(data)).Code, "旧代次不能覆盖新决定")
	w = send("GET", "/api/admin/integrations/"+binding.ID+"/audits", appTokens[61002], "")
	require.Equal(t, 200, w.Code)
	require.Contains(t, w.Body.String(), "admin_restricted")
	require.NotContains(t, w.Body.String(), "PayloadJSON")
}
