package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

// TestFeedbackSubmitRejectsOversizedAttachment 走完整 Submit 链路，验证编码后 MIME 超限时
// 返回 HTTP 400 与"截图过大"提示（而不是静默降级或发送残缺邮件）。
func TestFeedbackSubmitRejectsOversizedAttachment(t *testing.T) {
	gin.SetMode(gin.TestMode)

	uploadDir := t.TempDir()
	t.Setenv("UPLOAD_DIR", uploadDir)
	big := bytes.Repeat([]byte{'A'}, 2048)
	if err := os.WriteFile(filepath.Join(uploadDir, "big.png"), big, 0o600); err != nil {
		t.Fatal(err)
	}

	db, err := gorm.Open(sqlite.Open("file:"+strings.ReplaceAll(t.Name(), "/", "_")+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.File{}, &models.FileUploadGrant{}); err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.User{ID: 7, StudentID: "tester", Nickname: "测试用户"}).Error; err != nil {
		t.Fatal(err)
	}
	file := models.File{
		Hash:        "big",
		Path:        "/uploads/big.png",
		MimeType:    "image/png",
		Size:        int64(len(big)),
		UploaderID:  7,
		AccessScope: models.FileAccessPrivate,
	}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.FileUploadGrant{FileID: file.ID, UserID: 7}).Error; err != nil {
		t.Fatal(err)
	}

	oldSize := maxEmailMessageSize
	maxEmailMessageSize = 512
	defer func() { maxEmailMessageSize = oldSize }()

	oldSMTP := VerifyCodeConfig
	defer func() { VerifyCodeConfig = oldSMTP }()
	VerifyCodeConfig = struct {
		SMTPHost string
		SMTPPort string
		SMTPUser string
		SMTPPass string
		SMTPFrom string
	}{SMTPHost: "smtp.test.example", SMTPPort: "25", SMTPUser: "u", SMTPPass: "p"}

	handler := NewFeedbackHandler(db, uploadDir)
	router := gin.New()
	router.Use(func(c *gin.Context) {
		c.Set("user_id", uint(7))
		c.Next()
	})
	router.POST("/api/feedback", handler.Submit)

	payload, _ := json.Marshal(map[string]interface{}{
		"content":   "这是一条反馈",
		"type":      "bug",
		"image_ids": []uint{file.ID},
	})
	req := httptest.NewRequest(http.MethodPost, "/api/feedback", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400, body=%s", recorder.Code, recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), "截图过大") {
		t.Fatalf("body should mention 截图过大, got %s", recorder.Body.String())
	}
}
