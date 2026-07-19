package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestAIAccessMiddlewareEnforcesSwitchAndWhitelist(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tests := []struct {
		name       string
		enabled    bool
		internal   bool
		userID     uint
		role       string
		wantStatus int
	}{
		{"总开关关闭", false, true, 18, "user", http.StatusServiceUnavailable},
		{"非白名单用户", true, true, 19, "user", http.StatusForbidden},
		{"白名单用户", true, true, 18, "user", http.StatusNoContent},
		{"管理员", true, true, 19, "admin", http.StatusNoContent},
		{"超级管理员", true, true, 20, "super_admin", http.StatusNoContent},
		{"正式开放", true, false, 19, "user", http.StatusNoContent},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			router := gin.New()
			router.Use(func(c *gin.Context) {
				c.Set("user_id", tt.userID)
				c.Set("role", tt.role)
			})
			router.Use(AIAccessMiddleware(tt.enabled, tt.internal, []string{"18"}))
			router.GET("/ai", func(c *gin.Context) { c.Status(http.StatusNoContent) })
			response := httptest.NewRecorder()
			router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/ai", nil))
			if response.Code != tt.wantStatus {
				t.Fatalf("status=%d want=%d body=%s", response.Code, tt.wantStatus, response.Body.String())
			}
		})
	}
}
