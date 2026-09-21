package handlers

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func TestCreateSecurityBlockFailsClosedWhenDisabled(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	handler := NewSecurityAdminHandler(db, services.NewSecurityEventService(db, "security-test-secret", time.Now))
	handler.SetProtectionConfig(false, []string{"127.0.0.1/32"}, "")
	response := performSecurityBlockRequest(handler, `{"source_key":"0123456789012345678901234567890123456789012345678901234567890123","duration_minutes":15}`)
	if response.Code != http.StatusServiceUnavailable || !bytes.Contains(response.Body.Bytes(), []byte("security_block_disabled")) {
		t.Fatalf("封禁关闭时响应错误: %d %s", response.Code, response.Body.String())
	}
}

func TestCreateSecurityBlockRejectsInvalidHistoricalAttribution(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	key := "0123456789012345678901234567890123456789012345678901234567890123"
	now := time.Now().UTC()
	if err := db.Create(&models.SecurityEvent{
		BucketKey: "historical-invalid", EventType: "login_bruteforce", Severity: models.SecuritySeverityHigh,
		Status: models.SecurityEventStatusActive, Route: "/api/login", Method: "POST", SourceIPHash: key,
		SourceAttributionValid: false, Action: "blocked", FirstSeenAt: now.Add(-24 * time.Hour), LastSeenAt: now,
		CreatedAt: now, UpdatedAt: now,
	}).Error; err != nil {
		t.Fatalf("写入历史安全事件失败: %v", err)
	}
	if err := db.Model(&models.SecurityEvent{}).Where("bucket_key = ?", "historical-invalid").Update("source_attribution_valid", false).Error; err != nil {
		t.Fatalf("标记历史来源归因失败: %v", err)
	}
	handler := NewSecurityAdminHandler(db, services.NewSecurityEventService(db, "security-test-secret", time.Now))
	handler.SetProtectionConfig(true, []string{"127.0.0.1/32"}, "")
	response := performSecurityBlockRequest(handler, `{"source_key":"0123456789012345678901234567890123456789012345678901234567890123","duration_minutes":15}`)
	if response.Code != http.StatusConflict || !bytes.Contains(response.Body.Bytes(), []byte("security_source_attribution_invalid")) {
		t.Fatalf("历史无效归因未被拒绝: %d %s", response.Code, response.Body.String())
	}
}

func performSecurityBlockRequest(handler *SecurityAdminHandler, body string) *httptest.ResponseRecorder {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.POST("/blocks", func(c *gin.Context) {
		c.Set("user_id", uint(1))
		handler.CreateBlock(c)
	})
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/blocks", bytes.NewBufferString(body)))
	return recorder
}
