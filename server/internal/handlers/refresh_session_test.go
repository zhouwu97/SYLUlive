package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/golang-jwt/jwt/v5"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func TestRefreshSessionRotatesAndStoresOnlyHash(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	// 重复执行迁移不应改变已有会话表结构或报错。
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	h := NewAuthHandler(db, "test-secret")
	ctx, _ := gin.CreateTestContext(httptest.NewRecorder())
	ctx.Request = httptest.NewRequest("POST", "/api/refresh", nil)
	ctx.Request.Header.Set("User-Agent", "test-device")
	raw, family, err := h.issueRefreshSession(user.ID, ctx)
	require.NoError(t, err)
	var stored models.RefreshToken
	require.NoError(t, db.First(&stored).Error)
	require.NotEqual(t, raw, stored.TokenHash)
	require.NotEqual(t, raw, family)
	require.Equal(t, family, stored.TokenFamily)

	access, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, "test-secret", family)
	require.NoError(t, err)
	claims := &middleware.Claims{}
	parsed, err := jwt.ParseWithClaims(access, claims, func(_ *jwt.Token) (interface{}, error) {
		return []byte("test-secret"), nil
	})
	require.NoError(t, err)
	require.True(t, parsed.Valid)
	require.Equal(t, family, claims.SessionID)
	require.NotEqual(t, raw, claims.SessionID)

	reqBody, _ := json.Marshal(map[string]string{"refresh_token": raw})
	req := httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "test-device")
	rec := httptest.NewRecorder()
	ctx, _ = gin.CreateTestContext(rec)
	ctx.Request = req
	h.Refresh(ctx)
	require.Equal(t, 200, rec.Code)
	var count int64
	db.Model(&models.RefreshToken{}).Where("revoked_at IS NULL").Count(&count)
	require.Equal(t, int64(1), count)
	require.True(t, stored.ExpiresAt.After(time.Now()))
	var firstPayload map[string]interface{}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &firstPayload))
	rotatedRaw, _ := firstPayload["refresh_token"].(string)
	require.NotEmpty(t, rotatedRaw)
	// 同设备在短窗口重试旧凭据时，返回同一个轮换结果以恢复已丢失的响应。
	rec = httptest.NewRecorder()
	ctx, _ = gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(reqBody))
	ctx.Request.Header.Set("Content-Type", "application/json")
	ctx.Request.Header.Set("User-Agent", "test-device")
	h.Refresh(ctx)
	require.Equal(t, 200, rec.Code)
	var recoveredPayload map[string]interface{}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &recoveredPayload))
	require.Equal(t, rotatedRaw, recoveredPayload["refresh_token"])

	// 指纹变化后的旧凭据仍按重放攻击处理，并撤销整个会话族。
	rec = httptest.NewRecorder()
	ctx, _ = gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(reqBody))
	ctx.Request.Header.Set("Content-Type", "application/json")
	ctx.Request.Header.Set("User-Agent", "other-device")
	h.Refresh(ctx)
	require.Equal(t, 401, rec.Code)
	require.Contains(t, rec.Body.String(), "refresh_token_reused")
	db.Model(&models.RefreshToken{}).Where("revoked_at IS NULL").Count(&count)
	require.Zero(t, count)
}

func TestRefreshSessionConcurrentSameDeviceGetsRecoverableResult(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	h := NewAuthHandler(db, "test-secret")
	seedCtx, _ := gin.CreateTestContext(httptest.NewRecorder())
	seedCtx.Request = httptest.NewRequest("POST", "/api/refresh", nil)
	raw, _, err := h.issueRefreshSession(user.ID, seedCtx)
	require.NoError(t, err)

	type result struct {
		code         int
		refreshToken string
	}
	results := make(chan result, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body, _ := json.Marshal(map[string]string{"refresh_token": raw})
			rec := httptest.NewRecorder()
			ctx, _ := gin.CreateTestContext(rec)
			ctx.Request = httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(body))
			ctx.Request.Header.Set("Content-Type", "application/json")
			h.Refresh(ctx)
			var payload map[string]interface{}
			_ = json.Unmarshal(rec.Body.Bytes(), &payload)
			refreshToken, _ := payload["refresh_token"].(string)
			results <- result{code: rec.Code, refreshToken: refreshToken}
		}()
	}
	wg.Wait()
	close(results)

	var success int
	var refreshTokens []string
	for got := range results {
		if got.code == 200 {
			success++
			refreshTokens = append(refreshTokens, got.refreshToken)
		}
	}
	require.Equal(t, 2, success)
	require.Len(t, refreshTokens, 2)
	require.Equal(t, refreshTokens[0], refreshTokens[1])
}

func TestRefreshSessionRecoveryAllowsNetworkChangeBeforeRotation(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	h := NewAuthHandler(db, "test-secret")
	seedCtx, _ := gin.CreateTestContext(httptest.NewRecorder())
	seedCtx.Request = httptest.NewRequest(http.MethodPost, "/api/refresh", nil)
	seedCtx.Request.RemoteAddr = "192.0.2.10:1234"
	seedCtx.Request.Header.Set("User-Agent", "old-network-device")
	raw, _, err := h.issueRefreshSession(user.ID, seedCtx)
	require.NoError(t, err)
	body, _ := json.Marshal(map[string]string{"refresh_token": raw})

	refresh := func() *httptest.ResponseRecorder {
		record := httptest.NewRecorder()
		ctx, _ := gin.CreateTestContext(record)
		ctx.Request = httptest.NewRequest(http.MethodPost, "/api/refresh", bytes.NewReader(body))
		ctx.Request.RemoteAddr = "198.51.100.20:5678"
		ctx.Request.Header.Set("Content-Type", "application/json")
		ctx.Request.Header.Set("User-Agent", "same-device")
		h.Refresh(ctx)
		return record
	}

	first := refresh()
	require.Equal(t, http.StatusOK, first.Code, first.Body.String())
	second := refresh()
	require.Equal(t, http.StatusOK, second.Code, second.Body.String())
	var firstPayload, secondPayload map[string]interface{}
	require.NoError(t, json.Unmarshal(first.Body.Bytes(), &firstPayload))
	require.NoError(t, json.Unmarshal(second.Body.Bytes(), &secondPayload))
	require.Equal(t, firstPayload["refresh_token"], secondPayload["refresh_token"])
}

func TestRefreshSessionMigratesLegacyExposedFamily(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	raw := "legacy-refresh-token"
	require.NoError(t, db.Create(&models.RefreshToken{
		UserID: user.ID, TokenVersion: user.TokenVersion, TokenHash: refreshHash(raw),
		TokenFamily: raw, ExpiresAt: time.Now().Add(time.Hour),
		CreatedIPHash: refreshHash("192.0.2.1"), UserAgentHash: refreshHash("legacy-device"),
	}).Error)

	body, _ := json.Marshal(map[string]string{"refresh_token": raw})
	request := httptest.NewRequest(http.MethodPost, "/api/refresh", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "legacy-device")
	response := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(response)
	ctx.Request = request
	NewAuthHandler(db, "test-secret").Refresh(ctx)
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())

	var active models.RefreshToken
	require.NoError(t, db.Where("revoked_at IS NULL").First(&active).Error)
	require.NotEqual(t, raw, active.TokenFamily)
	var payload map[string]interface{}
	require.NoError(t, json.Unmarshal(response.Body.Bytes(), &payload))
	access, _ := payload["token"].(string)
	claims := &middleware.Claims{}
	parsed, err := jwt.ParseWithClaims(access, claims, func(_ *jwt.Token) (interface{}, error) {
		return []byte("test-secret"), nil
	})
	require.NoError(t, err)
	require.True(t, parsed.Valid)
	require.Equal(t, active.TokenFamily, claims.SessionID)
	require.NotEqual(t, raw, claims.SessionID)
}

func TestRefreshSessionMigratesAlreadyRotatedLegacyChain(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	legacyFamily := "legacy-family"
	oldRaw := "legacy-refresh-0"
	currentRaw := "legacy-refresh-1"
	now := time.Now()
	first := models.RefreshToken{
		UserID: user.ID, TokenVersion: user.TokenVersion, TokenHash: refreshHash(oldRaw),
		TokenFamily: legacyFamily, ExpiresAt: now.Add(time.Hour), FamilyVersion: 0,
		UserAgentHash: refreshHash("legacy-device"),
	}
	require.NoError(t, db.Create(&first).Error)
	current := models.RefreshToken{
		UserID: user.ID, TokenVersion: user.TokenVersion, TokenHash: refreshHash(currentRaw),
		TokenFamily: legacyFamily, ExpiresAt: now.Add(time.Hour), FamilyVersion: 0,
		UserAgentHash: refreshHash("legacy-device"),
	}
	require.NoError(t, db.Create(&current).Error)
	usedAt := time.Now()
	require.NoError(t, db.Model(&first).Updates(map[string]interface{}{
		"revoked_at": usedAt, "last_used_at": usedAt, "replaced_by": current.ID,
	}).Error)

	body, _ := json.Marshal(map[string]string{"refresh_token": currentRaw})
	request := httptest.NewRequest(http.MethodPost, "/api/refresh", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("User-Agent", "legacy-device")
	response := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(response)
	ctx.Request = request
	NewAuthHandler(db, "test-secret").Refresh(ctx)
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())

	var active models.RefreshToken
	require.NoError(t, db.Where("revoked_at IS NULL").First(&active).Error)
	require.NotEqual(t, legacyFamily, active.TokenFamily)
	require.Equal(t, 2, active.FamilyVersion)
}

func TestRefreshSessionCookieTransportDoesNotExposeToken(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	h := NewAuthHandler(db, "test-secret")
	seedCtx, _ := gin.CreateTestContext(httptest.NewRecorder())
	seedCtx.Request = httptest.NewRequest("POST", "/api/refresh", nil)
	raw, _, err := h.issueRefreshSession(user.ID, seedCtx)
	require.NoError(t, err)
	body, _ := json.Marshal(map[string]string{"refresh_token": raw})
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(body))
	ctx.Request.Header.Set("Content-Type", "application/json")
	ctx.Request.Header.Set("X-Auth-Transport", "cookie")
	h.Refresh(ctx)
	require.Equal(t, 200, rec.Code)
	require.NotContains(t, rec.Body.String(), "refresh_token")
	require.NotContains(t, rec.Body.String(), "\"token\"")
	require.NotEmpty(t, rec.Header().Get("Set-Cookie"))
}

func TestLogoutRevokesAccessTokenSessionFamily(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.RefreshToken{}, &models.UserLegalConsent{}))
	user := models.User{PasswordHash: "x", AccountStatus: "active", Role: models.RoleUser}
	require.NoError(t, db.Create(&user).Error)
	for _, document := range models.RequiredLegalDocuments(false) {
		require.NoError(t, db.Create(&models.UserLegalConsent{
			UserID: user.ID, Document: document, Version: models.LegalDocumentVersion, AcceptedAt: time.Now(),
		}).Error)
	}
	require.NoError(t, db.Create(&models.RefreshToken{
		UserID: user.ID, TokenHash: refreshHash("current-a"), TokenFamily: "family-a", ExpiresAt: time.Now().Add(time.Hour),
	}).Error)
	require.NoError(t, db.Create(&models.RefreshToken{
		UserID: user.ID, TokenHash: refreshHash("current-b"), TokenFamily: "family-b", ExpiresAt: time.Now().Add(time.Hour),
	}).Error)
	access, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, "test-secret", "family-a")
	require.NoError(t, err)

	h := NewAuthHandler(db, "test-secret")
	router := gin.New()
	router.POST("/api/logout", middleware.AuthMiddleware(db, "test-secret"), h.Logout)
	body, _ := json.Marshal(map[string]string{"refresh_token": "stale-before-rotation"})
	request := httptest.NewRequest(http.MethodPost, "/api/logout", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+access)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	require.Equal(t, http.StatusOK, response.Code, response.Body.String())

	var familyA, familyB int64
	require.NoError(t, db.Model(&models.RefreshToken{}).Where("token_family = ? AND revoked_at IS NULL", "family-a").Count(&familyA).Error)
	require.NoError(t, db.Model(&models.RefreshToken{}).Where("token_family = ? AND revoked_at IS NULL", "family-b").Count(&familyB).Error)
	require.Zero(t, familyA)
	require.Equal(t, int64(1), familyB)
}
