package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func securityResolutionFixture(t *testing.T) (*gorm.DB, *gin.Engine) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	sqlDB.SetMaxOpenConns(1)
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.AdminLog{}, &models.User{}); err != nil {
		t.Fatal(err)
	}
	h := NewSecurityAdminHandler(db, nil)
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", uint(7)); c.Set("role", "admin"); c.Next() })
	r.POST("/events/:id/resolve", h.Resolve)
	r.POST("/events/:id/false-positive", h.FalsePositive)
	r.GET("/events", h.ListEvents)
	return db, r
}

func resolutionRequest(r *gin.Engine, method, path, body string) *httptest.ResponseRecorder {
	response := httptest.NewRecorder()
	r.ServeHTTP(response, httptest.NewRequest(method, path, strings.NewReader(body)))
	return response
}

func TestSecurityResolutionPreservesFirstDecision(t *testing.T) {
	for _, firstAction := range []string{"resolve", "false-positive"} {
		t.Run(firstAction, func(t *testing.T) {
			db, r := securityResolutionFixture(t)
			event := models.SecurityEvent{BucketKey: "decision", EventType: "login_bruteforce", Status: "active"}
			if err := db.Create(&event).Error; err != nil {
				t.Fatal(err)
			}
			note := strings.Repeat("中", 500)
			body, _ := json.Marshal(map[string]string{"note": note})
			response := resolutionRequest(r, http.MethodPost, "/events/1/"+firstAction, string(body))
			if response.Code != http.StatusOK {
				t.Fatalf("首次处理失败: %d %s", response.Code, response.Body.String())
			}
			var first models.SecurityEvent
			if err := db.First(&first, 1).Error; err != nil {
				t.Fatal(err)
			}
			if first.ResolutionNote != note || first.ResolvedBy == nil || *first.ResolvedBy != 7 {
				t.Fatal("中文备注或处理人丢失")
			}
			second := "false-positive"
			if firstAction == second {
				second = "resolve"
			}
			response = resolutionRequest(r, http.MethodPost, "/events/1/"+second, `{"note":"试图覆盖"}`)
			if response.Code != http.StatusConflict || !bytes.Contains(response.Body.Bytes(), []byte("security_event_already_handled")) {
				t.Fatalf("重复处置应返回冲突: %d %s", response.Code, response.Body.String())
			}
			var after models.SecurityEvent
			if err := db.First(&after, 1).Error; err != nil {
				t.Fatal(err)
			}
			if after.Status != first.Status || after.ResolutionNote != first.ResolutionNote || !after.ResolvedAt.Equal(*first.ResolvedAt) {
				t.Fatal("旧结论被覆盖")
			}
			var logs int64
			if err := db.Model(&models.AdminLog{}).Count(&logs).Error; err != nil || logs != 1 {
				t.Fatalf("处置审计重复: %d %v", logs, err)
			}
		})
	}
}

func TestSecurityResolutionErrorsDoNotMutateEvent(t *testing.T) {
	db, r := securityResolutionFixture(t)
	if err := db.Create(&models.SecurityEvent{BucketKey: "errors", EventType: "login_bruteforce", Status: "active"}).Error; err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		path, body string
		status     int
	}{
		{"/events/0/resolve", `{}`, 400},
		{"/events/invalid/resolve", `{}`, 400},
		{"/events/1/resolve", `{"note":`, 400},
		{"/events/1/resolve", `{"note":123}`, 400},
		{"/events/999/resolve", `{}`, 404},
	} {
		if response := resolutionRequest(r, http.MethodPost, tc.path, tc.body); response.Code != tc.status {
			t.Fatalf("%s: %d %s", tc.path, response.Code, response.Body.String())
		}
	}
	var event models.SecurityEvent
	if err := db.First(&event, 1).Error; err != nil {
		t.Fatal(err)
	}
	if event.Status != "active" || event.ResolvedAt != nil {
		t.Fatal("无效请求修改了事件")
	}
	if err := db.Migrator().DropTable(&models.SecurityEvent{}); err != nil {
		t.Fatal(err)
	}
	if response := resolutionRequest(r, http.MethodPost, "/events/1/resolve", `{}`); response.Code != 500 {
		t.Fatalf("数据库故障不能伪装成不存在: %d", response.Code)
	}
}

func TestSecurityNotesUseCharacterLimits(t *testing.T) {
	text := "  " + strings.Repeat("中🙂", 300) + "  "
	for _, limit := range []int{200, 500} {
		result := truncateSecurityText(text, limit)
		if !utf8.ValidString(result) || utf8.RuneCountInString(result) != limit {
			t.Fatalf("字符截断损坏: %q", result)
		}
	}
}

func TestConcurrentSecurityResolutionsHaveOneWinner(t *testing.T) {
	db, r := securityResolutionFixture(t)
	if err := db.Create(&models.SecurityEvent{BucketKey: "concurrent", EventType: "login_bruteforce", Status: "active"}).Error; err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	statuses := make(chan int, 2)
	var workers sync.WaitGroup
	for _, action := range []string{"resolve", "false-positive"} {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			statuses <- resolutionRequest(r, http.MethodPost, "/events/1/"+action, `{"note":"并发处置"}`).Code
		}()
	}
	close(start)
	workers.Wait()
	close(statuses)
	counts := map[int]int{}
	for status := range statuses {
		counts[status]++
	}
	if counts[http.StatusOK] != 1 || counts[http.StatusConflict] != 1 {
		t.Fatalf("并发处置必须只有一个成功: %v", counts)
	}
	var logs int64
	if err := db.Model(&models.AdminLog{}).Count(&logs).Error; err != nil || logs != 1 {
		t.Fatalf("并发写入了重复审计: %d %v", logs, err)
	}
}

func TestSecurityEventPaginationBoundsAndStableOrder(t *testing.T) {
	db, r := securityResolutionFixture(t)
	for _, key := range []string{"one", "two", "three"} {
		if err := db.Create(&models.SecurityEvent{BucketKey: key, EventType: "login_bruteforce", Status: "active"}).Error; err != nil {
			t.Fatal(err)
		}
	}
	for page, expectedID := range []int{3, 2, 1} {
		path := []string{"/events?limit=1&page=1", "/events?limit=1&page=2", "/events?limit=1&page=3"}[page]
		response := resolutionRequest(r, http.MethodGet, path, "")
		var data struct {
			Items []securityEventResponse `json:"items"`
			Total int                     `json:"total"`
		}
		if err := json.Unmarshal(response.Body.Bytes(), &data); err != nil {
			t.Fatal(err)
		}
		if response.Code != 200 || len(data.Items) != 1 || data.Items[0].ID != uint(expectedID) || data.Total != 3 {
			t.Fatalf("分页遗漏: %s", response.Body.String())
		}
	}
	if response := resolutionRequest(r, http.MethodGet, "/events?page=10001", ""); response.Code != 400 {
		t.Fatalf("超大页码未拒绝: %d", response.Code)
	}
}

func TestSecurityBlockReasonFitsDatabaseCharacterLimit(t *testing.T) {
	db, _ := securityResolutionFixture(t)
	if err := db.AutoMigrate(&models.SecurityBlock{}); err != nil {
		t.Fatal(err)
	}
	key := strings.Repeat("a", 64)
	if err := db.Create(&models.SecurityEvent{BucketKey: "block-note", EventType: "login_bruteforce", Status: "active", SourceIPHash: key, SourceAttributionValid: true}).Error; err != nil {
		t.Fatal(err)
	}
	h := NewSecurityAdminHandler(db, nil)
	h.SetProtectionConfig(true, nil, "")
	body, _ := json.Marshal(map[string]interface{}{"source_key": key, "duration_minutes": 15,
		"scope": "route", "route_prefix": "/api/login", "reason": strings.Repeat("中🙂", 300)})
	response := performSecurityBlockRequest(h, string(body))
	if response.Code != http.StatusCreated {
		t.Fatalf("中文封禁原因不能导致写入失败: %d %s", response.Code, response.Body.String())
	}
	var block models.SecurityBlock
	if err := db.First(&block).Error; err != nil {
		t.Fatal(err)
	}
	if !utf8.ValidString(block.Reason) || utf8.RuneCountInString(block.Reason) != 200 || block.ExpiresAt.Before(time.Now()) {
		t.Fatal("封禁原因超长或封禁未生效")
	}
}
