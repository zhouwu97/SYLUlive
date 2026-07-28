package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestAIAccessMiddlewareEnforcesOnlyGlobalSwitch(t *testing.T) {
	gin.SetMode(gin.TestMode)
	tests := []struct {
		name       string
		enabled    bool
		wantStatus int
	}{
		{"总开关关闭", false, http.StatusServiceUnavailable},
		{"普通用户开放", true, http.StatusNoContent},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			router := gin.New()
			router.Use(AIAccessMiddleware(tt.enabled))
			router.GET("/ai", func(c *gin.Context) { c.Status(http.StatusNoContent) })
			response := httptest.NewRecorder()
			router.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/ai", nil))
			if response.Code != tt.wantStatus {
				t.Fatalf("status=%d want=%d body=%s", response.Code, tt.wantStatus, response.Body.String())
			}
		})
	}
}
