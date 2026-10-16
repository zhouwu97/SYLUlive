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
		{"缺失 Origin 的同站子域请求", "", "same-site", 403},
		{"沙箱空来源", "null", "", 403},
		{"伪造用户信息 URL", "https://user@sylulive.online", "", 403},
		{"来源包含路径", "https://sylulive.online/path", "", 403},
		{"来源包含查询", "https://sylulive.online?x=1", "", 403},
		{"来源包含片段", "https://sylulive.online#x", "", 403},
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

func TestBrowserOriginGuardExplicitTrustedOrigin(t *testing.T) {
	r := gin.New()
	r.Use(BrowserOriginGuard("https://web.example.com"))
	r.POST("/api/write", func(c *gin.Context) { c.Status(http.StatusOK) })
	for _, tc := range []struct {
		origin string
		status int
	}{
		{"https://web.example.com", http.StatusOK},
		{"https://evil.example.com", http.StatusForbidden},
		{"https://web.example.com.evil.example", http.StatusForbidden},
	} {
		req := httptest.NewRequest(http.MethodPost, "https://api.example.com/api/write", nil)
		req.Header.Set("Origin", tc.origin)
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		require.Equal(t, tc.status, rec.Code)
	}
}

func TestTrustedProxySourceBoundaries(t *testing.T) {
	for _, tc := range []struct{ name, remote, forwarded, want string }{
		{"直连来源忽略伪造 XFF", "203.0.113.8:1234", "198.51.100.99", "203.0.113.8"},
		{"本机 Nginx 提供实际来源", "127.0.0.1:1234", "203.0.113.8", "203.0.113.8"},
		{"历史追加链忽略左侧伪造来源", "127.0.0.1:1234", "198.51.100.99, 203.0.113.8", "203.0.113.8"},
		{"不同真实出口保持区分", "127.0.0.1:1234", "203.0.113.9", "203.0.113.9"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := gin.New()
			require.NoError(t, r.SetTrustedProxies([]string{"127.0.0.1/32"}))
			r.GET("/source", func(c *gin.Context) { c.String(http.StatusOK, c.ClientIP()) })
			req := httptest.NewRequest(http.MethodGet, "/source", nil)
			req.RemoteAddr = tc.remote
			req.Header.Set("X-Forwarded-For", tc.forwarded)
			rec := httptest.NewRecorder()
			r.ServeHTTP(rec, req)
			require.Equal(t, tc.want, rec.Body.String())
		})
	}
}
