package handlers

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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

func TestUploadWritesNewFileIntoUploadDir(t *testing.T) {
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.File{}, &models.FileUploadGrant{}))
	user := models.User{PasswordHash: "test", Nickname: "upload-writer"}
	require.NoError(t, db.Create(&user).Error)

	uploadDir := t.TempDir()
	policy := services.NewUploadProtection(db, uploadDir, services.UploadProtectionConfig{
		PerMinuteCountLimit:  30,
		HourlyBytesLimit:     10 << 20,
		TemporaryUserCount:   10,
		TemporaryUserBytes:   10 << 20,
		TemporaryGlobalBytes: 10 << 20,
	})
	handler := NewUploadHandler(uploadDir, 10<<20, db)
	handler.SetUploadProtection(policy)

	payload := newPNGBytes(t, 24, 24)
	req, _ := createUploadMultipartRequest(t, "file", "new.png", payload)
	resp := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(resp)
	ctx.Request = req
	ctx.Set("user_id", user.ID)
	handler.Upload(ctx)
	require.Equal(t, http.StatusOK, resp.Code, resp.Body.String())

	var body map[string]interface{}
	require.NoError(t, json.Unmarshal(resp.Body.Bytes(), &body))
	require.NotNil(t, body["file_id"])

	// 回归：新文件必须通过磁盘路径写入 uploadDir，公开 URL（/uploads/...）只能进数据库记录。
	written := []string{}
	require.NoError(t, filepath.WalkDir(uploadDir, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() {
			written = append(written, path)
		}
		return nil
	}))
	require.Len(t, written, 1)
	onDisk, err := os.ReadFile(written[0])
	require.NoError(t, err)
	require.Equal(t, payload, onDisk)

	var record models.File
	require.NoError(t, db.Where("id = ?", uint(body["file_id"].(float64))).First(&record).Error)
	require.True(t, strings.HasPrefix(record.Path, "/uploads/"), "record.Path 必须是公开 URL: %s", record.Path)
}
