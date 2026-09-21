package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestUploadReturnsQuotaErrorBeforeWriting(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.File{}, &models.FileUploadGrant{}))
	user := models.User{PasswordHash: "test", Nickname: "upload-user"}
	require.NoError(t, db.Create(&user).Error)
	now := time.Now()
	require.NoError(t, db.Create(&models.File{
		Hash: "recent", Path: "/uploads/recent.png", Size: 1, MimeType: "image/png", UploaderID: user.ID,
		Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, CreatedAt: now,
	}).Error)
	policy := services.NewUploadProtection(db, t.TempDir(), services.UploadProtectionConfig{
		PerMinuteCountLimit:  1,
		HourlyBytesLimit:     1 << 20,
		TemporaryUserCount:   10,
		TemporaryUserBytes:   1 << 20,
		TemporaryGlobalBytes: 1 << 20,
	})
	handler := NewUploadHandler(t.TempDir(), 10<<20, db)
	handler.SetUploadProtection(policy)
	req, _ := createUploadMultipartRequest(t, "file", "test.png", newPNGBytes(t, 20, 20))
	resp := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(resp)
	ctx.Request = req
	ctx.Set("user_id", user.ID)
	handler.Upload(ctx)
	require.Equal(t, http.StatusTooManyRequests, resp.Code)
	var body map[string]interface{}
	require.NoError(t, json.Unmarshal(resp.Body.Bytes(), &body))
	require.Equal(t, "upload_quota_exceeded", body["code"])
}
