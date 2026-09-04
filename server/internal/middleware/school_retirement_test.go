package middleware

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

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
