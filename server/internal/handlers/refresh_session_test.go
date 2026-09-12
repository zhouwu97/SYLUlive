package handlers

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
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
	raw, err := h.issueRefreshToken(user.ID, "", ctx)
	require.NoError(t, err)
	var stored models.RefreshToken
	require.NoError(t, db.First(&stored).Error)
	require.NotEqual(t, raw, stored.TokenHash)

	reqBody, _ := json.Marshal(map[string]string{"refresh_token": raw})
	req := httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	ctx, _ = gin.CreateTestContext(rec)
	ctx.Request = req
	h.Refresh(ctx)
	require.Equal(t, 200, rec.Code)
	var count int64
	db.Model(&models.RefreshToken{}).Where("revoked_at IS NULL").Count(&count)
	require.Equal(t, int64(1), count)
	require.True(t, stored.ExpiresAt.After(time.Now()))
	// 轮换前的旧凭据再次使用必须被识别为重放。
	rec = httptest.NewRecorder()
	ctx, _ = gin.CreateTestContext(rec)
	ctx.Request = httptest.NewRequest("POST", "/api/refresh", bytes.NewReader(reqBody))
	ctx.Request.Header.Set("Content-Type", "application/json")
	h.Refresh(ctx)
	require.Equal(t, 401, rec.Code)
	require.Contains(t, rec.Body.String(), "refresh_token_reused")
}

func TestRefreshSessionConcurrentUseOnlyOneSucceeds(t *testing.T) {
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
	raw, err := h.issueRefreshToken(user.ID, "", seedCtx)
	require.NoError(t, err)

	type result struct{ code int }
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
			results <- result{code: rec.Code}
		}()
	}
	wg.Wait()
	close(results)

	var success, reused int
	for got := range results {
		switch got.code {
		case 200:
			success++
		case 401:
			reused++
		}
	}
	require.Equal(t, 1, success)
	require.Equal(t, 1, reused)
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
	raw, err := h.issueRefreshToken(user.ID, "", seedCtx)
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
