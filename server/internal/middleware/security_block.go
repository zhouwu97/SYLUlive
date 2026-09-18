package middleware

import (
	"log"
	"net/http"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
)

var securityBlockReadinessWarning sync.Once

type securityBlockHealthReporter interface {
	SetSecurityBlockDegraded(bool)
}

// SecurityBlockMiddleware 只在高风险 API 路径查询临时来源封禁，普通静态/读请求不增加数据库查询。
func SecurityBlockMiddleware(checker interface {
	IsBlocked(clientIP, route string) (bool, error)
}) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !isSensitiveSecurityRoute(c.Request.URL.Path) {
			c.Next()
			return
		}
		blocked, err := checker.IsBlocked(c.ClientIP(), c.Request.URL.Path)
		if err != nil {
			if reporter, ok := checker.(securityBlockHealthReporter); ok {
				reporter.SetSecurityBlockDegraded(true)
			}
			securityBlockReadinessWarning.Do(func() {
				log.Printf("ERROR security block unavailable, fail-open: %v", err)
			})
			// 附加封禁层查询失败时 fail-open；健康检查会同步显示 degraded。
			c.Next()
			return
		}
		if reporter, ok := checker.(securityBlockHealthReporter); ok {
			reporter.SetSecurityBlockDegraded(false)
		}
		if blocked {
			c.Header("Retry-After", "60")
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "当前来源暂时受限，请稍后再试", "code": "security_source_blocked"})
			c.Abort()
			return
		}
		c.Next()
	}
}

func isSensitiveSecurityRoute(path string) bool {
	return strings.HasPrefix(path, "/api/login") ||
		strings.HasPrefix(path, "/api/password/") ||
		strings.HasPrefix(path, "/api/register") ||
		strings.HasPrefix(path, "/api/send_code") ||
		strings.HasPrefix(path, "/api/verify_code") ||
		strings.HasPrefix(path, "/api/search") ||
		strings.HasPrefix(path, "/api/posts") ||
		strings.HasPrefix(path, "/api/messages") ||
		strings.HasPrefix(path, "/api/feedback")
}
