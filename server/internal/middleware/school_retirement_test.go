package middleware

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
)

type countingRequestBody struct {
	reader io.Reader
	reads  atomic.Int32
}

func (b *countingRequestBody) Read(p []byte) (int, error) {
	b.reads.Add(1)
	return b.reader.Read(p)
}

func (b *countingRequestBody) Close() error { return nil }

func TestSchoolAuthorityRetiredMiddlewareStopsBeforeHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	called := false
	router.POST("/api/edu/bind", SchoolAuthorityRetiredMiddleware, func(c *gin.Context) {
		called = true
		c.Status(http.StatusOK)
	})
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/api/edu/bind", strings.NewReader(`{"edu_password":"must-not-be-read"}`)))
	if recorder.Code != http.StatusGone || called {
		t.Fatalf("退役中间件未在业务处理前短路: status=%d called=%t", recorder.Code, called)
	}
}

func TestSchoolAuthorityRetirementGateStopsBeforeIdempotencyBodyRead(t *testing.T) {
	db := openIdempotencyTestDB(t)
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(SchoolAuthorityRetirementGate(true), IdempotencyMiddleware(db))
	router.POST("/api/edu/bind", func(c *gin.Context) {
		t.Fatal("退役请求不应进入业务处理器")
	})

	body := &countingRequestBody{reader: bytes.NewBufferString(`{"student_id":"2026000001","password":"must-not-be-read"}`)}
	req := httptest.NewRequest(http.MethodPost, "/api/edu/bind", nil)
	req.Body = body
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", "retired-school-route")
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, req)

	if recorder.Code != http.StatusGone {
		t.Fatalf("退役请求状态码=%d，期望 410，响应=%s", recorder.Code, recorder.Body.String())
	}
	if got := body.reads.Load(); got != 0 {
		t.Fatalf("退役请求 body 被读取 %d 次，期望为 0", got)
	}
	var count int64
	if err := db.Model(&models.IdempotencyRecord{}).Count(&count).Error; err != nil {
		t.Fatalf("查询幂等记录失败: %v", err)
	}
	if count != 0 {
		t.Fatalf("退役请求不应创建幂等记录，实际=%d", count)
	}
}

func TestSchoolAuthorityRetirementGateMatchesAllRetiredPersonalPaths(t *testing.T) {
	for _, path := range []string{
		"/api/edu",
		"/api/edu/bind/",
		"/api/erke/scores",
		"/api/personal-snapshots/erke",
		"/api/register_with_edu",
		"/api/forgot_password",
		"/api/password/edu/reset",
		"/api/login_edu",
	} {
		if !isSchoolAuthorityRetiredPath(http.MethodPost, path) {
			t.Errorf("退役个人路径未命中早期闸门: %s", path)
		}
	}

	for _, path := range []string{"/api/login", "/api/posts", "/health"} {
		if isSchoolAuthorityRetiredPath(http.MethodPost, path) {
			t.Errorf("非教务路径错误命中早期闸门: %s", path)
		}
	}
}
