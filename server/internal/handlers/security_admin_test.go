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

func TestBlockEventSourceResolvesEventAndWritesSecurityLogs(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.AdminLog{}, &models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.User{Nickname: "值班管理员", Email: "admin@example.test", Role: models.RoleAdmin}).Error; err != nil {
		t.Fatal(err)
	}
	key := "0123456789012345678901234567890123456789012345678901234567890123"
	now := time.Now().UTC()
	event := models.SecurityEvent{
		BucketKey: "event-block", EventType: "admin_login_new_device", Severity: models.SecuritySeverityHigh,
		Status: models.SecurityEventStatusActive, Route: "/api/login", Method: "POST", SourceIPHash: key,
		SourceAttributionValid: true, Action: "observed", FirstSeenAt: now, LastSeenAt: now, CreatedAt: now, UpdatedAt: now,
	}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	handler := NewSecurityAdminHandler(db, services.NewSecurityEventService(db, "security-test-secret", time.Now))
	handler.SetProtectionConfig(true, []string{"127.0.0.1/32"}, "")
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(func(c *gin.Context) { c.Set("user_id", uint(1)); c.Set("role", string(models.RoleAdmin)) })
	router.POST("/events/:id/block", handler.BlockEventSource)
	router.GET("/logs", handler.ListSecurityLogs)
	router.GET("/blocks", handler.ListBlocks)
	block := func(body string) *httptest.ResponseRecorder {
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/events/"+strconv.FormatUint(uint64(event.ID), 10)+"/block", bytes.NewBufferString(body)))
		return recorder
	}

	for _, body := range []string{
		`{"scope":"all","duration_minutes":1440,"reason":"全站"}`,
		`{"scope":"account","duration_minutes":10080,"reason":"一周"}`,
		`{"scope":"account","duration_minutes":1440,"reason":""}`,
	} {
		if response := block(body); response.Code != http.StatusBadRequest {
			t.Fatalf("越权或无效封禁未拒绝 %s: %d %s", body, response.Code, response.Body.String())
		}
	}
	if response := block(`{"scope":"account","duration_minutes":1440,"reason":"非本人新设备登录"}`); response.Code != http.StatusCreated || !bytes.Contains(response.Body.Bytes(), []byte(`"event_resolved":true`)) {
		t.Fatalf("从事件封禁失败: %d %s", response.Code, response.Body.String())
	}
	var stored models.SecurityEvent
	if err := db.First(&stored, event.ID).Error; err != nil {
		t.Fatal(err)
	}
	if stored.Status != models.SecurityEventStatusResolved || stored.ResolvedBy == nil || *stored.ResolvedBy != 1 || stored.ResolutionNote != "已封禁来源 1 天：非本人新设备登录" {
		t.Fatalf("封禁后事件未结案: %+v", stored)
	}
	var blocks []models.SecurityBlock
	if err := db.Find(&blocks).Error; err != nil || len(blocks) < 2 || blocks[0].ExpiresAt.Sub(blocks[0].CreatedAt) != 24*time.Hour {
		t.Fatalf("账号接口封禁未按 1 天写入: %v %+v", err, blocks)
	}

	logs := httptest.NewRecorder()
	router.ServeHTTP(logs, httptest.NewRequest(http.MethodGet, "/logs", nil))
	for _, want := range []string{"security_block_created", "security_event_resolved", "值班管理员", "非本人新设备登录"} {
		if !bytes.Contains(logs.Body.Bytes(), []byte(want)) {
			t.Fatalf("操作记录缺少 %s: %s", want, logs.Body.String())
		}
	}
	list := httptest.NewRecorder()
	router.ServeHTTP(list, httptest.NewRequest(http.MethodGet, "/blocks", nil))
	if list.Code != http.StatusOK || bytes.Contains(list.Body.Bytes(), []byte(key)) {
		t.Fatalf("管理员封禁列表不应包含来源指纹原值: %d %s", list.Code, list.Body.String())
	}
}
