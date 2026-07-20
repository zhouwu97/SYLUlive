package middleware

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
)

// AIAccessMiddleware 落实 AI 总开关与服务端内测白名单，客户端参数无权绕过。
func AIAccessMiddleware(enabled, internalTestOnly bool, allowedUserIDs []string) gin.HandlerFunc {
	allowed := make(map[string]struct{}, len(allowedUserIDs))
	for _, id := range allowedUserIDs {
		allowed[id] = struct{}{}
	}
	return func(c *gin.Context) {
		if !enabled {
			writeAPIError(c, http.StatusServiceUnavailable, "ai_disabled", "AI 助手暂未开放")
			c.Abort()
			return
		}
		if internalTestOnly {
			userID := strconv.FormatUint(uint64(c.GetUint("user_id")), 10)
			role := c.GetString("role")
			_, whitelisted := allowed[userID]
			if !whitelisted && role != "admin" && role != "super_admin" {
				writeAPIError(c, http.StatusForbidden, "ai_internal_test_only", "AI 助手当前仅对内测用户开放")
				c.Abort()
				return
			}
		}
		c.Next()
	}
}
