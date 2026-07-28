package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// AIAccessMiddleware 只落实 AI 总开关；用户身份由上游认证中间件统一校验。
func AIAccessMiddleware(enabled bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !enabled {
			writeAPIError(c, http.StatusServiceUnavailable, "ai_disabled", "AI 助手暂未开放")
			c.Abort()
			return
		}
		c.Next()
	}
}
