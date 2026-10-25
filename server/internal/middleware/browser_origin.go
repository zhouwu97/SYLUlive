package middleware

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"net/url"
	"strings"
)

// BrowserOriginGuard 校验浏览器写请求的来源，保留原生客户端无 Origin 的调用方式。
func BrowserOriginGuard(trustedOrigins ...string) gin.HandlerFunc {
	allowed := make(map[string]struct{}, len(trustedOrigins))
	for _, origin := range trustedOrigins {
		if origin = strings.TrimSpace(origin); origin != "" {
			allowed[origin] = struct{}{}
		}
	}
	return func(c *gin.Context) {
		if c.Request.Method == http.MethodGet || c.Request.Method == http.MethodHead || c.Request.Method == http.MethodOptions {
			c.Next()
			return
		}
		origin := c.GetHeader("Origin")
		if origin == "" {
			if site := c.GetHeader("Sec-Fetch-Site"); site == "cross-site" || site == "same-site" {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"code": "origin_rejected", "error": "请求来源不受信任"})
				return
			}
			c.Next()
			return
		}
		u, err := url.Parse(origin)
		_, explicitlyAllowed := allowed[origin]
		if err != nil || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "https" && u.Scheme != "http") || (!strings.EqualFold(u.Host, c.Request.Host) && !explicitlyAllowed) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"code": "origin_rejected", "error": "请从本站页面发起操作"})
			return
		}
		c.Next()
	}
}
