package middleware

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"net/url"
	"strings"
)

// BrowserOriginGuard 校验浏览器写请求的来源，保留原生客户端无 Origin 的调用方式。
func BrowserOriginGuard() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.Method == http.MethodGet || c.Request.Method == http.MethodHead || c.Request.Method == http.MethodOptions {
			c.Next()
			return
		}
		origin := c.GetHeader("Origin")
		if origin == "" {
			if c.GetHeader("Sec-Fetch-Site") == "cross-site" {
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"code": "origin_rejected", "error": "请求来源不受信任"})
				return
			}
			c.Next()
			return
		}
		u, err := url.Parse(origin)
		if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") || !strings.EqualFold(u.Host, c.Request.Host) {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"code": "origin_rejected", "error": "请从本站页面发起操作"})
			return
		}
		c.Next()
	}
}
