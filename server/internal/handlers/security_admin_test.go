package handlers

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strconv"
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

func TestSecurityBlockGroupCanBeRevokedAndDuplicateIsRejected(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatal(err)
	}
	key := "0123456789012345678901234567890123456789012345678901234567890123"
	now := time.Now().UTC()
	if err := db.Create(&models.SecurityEvent{
		BucketKey: "group-test", EventType: "login_bruteforce", Severity: models.SecuritySeverityHigh,
		Status: models.SecurityEventStatusActive, Route: "/api/login", Method: "POST", SourceIPHash: key,
		SourceAttributionValid: true, Action: "blocked", FirstSeenAt: now, LastSeenAt: now,
		CreatedAt: now, UpdatedAt: now,
	}).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewSecurityAdminHandler(db, services.NewSecurityEventService(db, "security-test-secret", time.Now))
	handler.SetProtectionConfig(true, []string{"127.0.0.1/32"}, "")
	body := `{"source_key":"` + key + `","duration_minutes":15,"scope":"account"}`
	if response := performSecurityBlockRequest(handler, body); response.Code != http.StatusCreated {
		t.Fatalf("创建封禁: %d %s", response.Code, response.Body.String())
	}
	var blocks []models.SecurityBlock
	if err := db.Find(&blocks).Error; err != nil {
		t.Fatal(err)
	}
	if len(blocks) < 2 || blocks[0].GroupID == "" {
		t.Fatalf("封禁未形成操作组: %+v", blocks)
	}
	for _, block := range blocks {
		if block.GroupID != blocks[0].GroupID {
			t.Fatal("同一次操作分成多个组")
		}
	}
	if response := performSecurityBlockRequest(handler, body); response.Code != http.StatusConflict {
		t.Fatalf("重复创建未拒绝: %d %s", response.Code, response.Body.String())
	}
	router := gin.New()
	router.DELETE("/blocks/:id", func(c *gin.Context) { c.Set("user_id", uint(1)); handler.RevokeBlock(c) })
	revoke := httptest.NewRecorder()
	router.ServeHTTP(revoke, httptest.NewRequest(http.MethodDelete, "/blocks/"+strconv.FormatUint(uint64(blocks[0].ID), 10), nil))
	if revoke.Code != http.StatusOK {
		t.Fatalf("撤销操作组: %d %s", revoke.Code, revoke.Body.String())
	}
	var active int64
	if err := db.Model(&models.SecurityBlock{}).Where("revoked_at IS NULL").Count(&active).Error; err != nil {
		t.Fatal(err)
	}
	if active != 0 {
		t.Fatalf("撤销后仍有 %d 条生效封禁", active)
	}
}
