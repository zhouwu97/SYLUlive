package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestRequestBodyLimitMiddlewareUsesPathSpecificLimit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	called := false
	router.Use(RequestBodyLimitMiddleware(4, BodyLimitRule{Prefix: "/upload", Limit: 8}))
	router.POST("/json", func(c *gin.Context) { called = true; c.Status(http.StatusOK) })
	router.POST("/upload", func(c *gin.Context) { called = true; c.Status(http.StatusOK) })

	tooLarge := httptest.NewRequest(http.MethodPost, "/json", strings.NewReader("12345"))
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, tooLarge)
	if recorder.Code != http.StatusRequestEntityTooLarge || called {
		t.Fatalf("普通请求应在处理器前被拒绝: status=%d called=%t", recorder.Code, called)
	}

	recorder = httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/upload", strings.NewReader("1234567")))
	if recorder.Code != http.StatusOK || !called {
		t.Fatalf("路径专用上限未生效: status=%d called=%t", recorder.Code, called)
	}
}
