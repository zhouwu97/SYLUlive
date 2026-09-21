package middleware

import (
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBrowserOriginGuard(t *testing.T) {
	for _, tc := range []struct {
		name, origin, site string
		status             int
	}{
		{"同源浏览器", "https://sylulive.online", "same-origin", 200},
		{"原生 App 无 Origin", "", "", 200},
		{"跨站表单", "https://other.example", "cross-site", 403},
		{"缺失 Origin 的跨站请求", "", "cross-site", 403},
		{"沙箱空来源", "null", "", 403},
		{"伪造用户信息 URL", "https://user@sylulive.online", "", 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := gin.New()
			r.Use(BrowserOriginGuard())
			r.POST("/api/write", func(c *gin.Context) { c.Status(http.StatusOK) })
			req := httptest.NewRequest(http.MethodPost, "https://sylulive.online/api/write", nil)
			req.Header.Set("Origin", tc.origin)
			req.Header.Set("Sec-Fetch-Site", tc.site)
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)
			require.Equal(t, tc.status, w.Code)
		})
	}
}
