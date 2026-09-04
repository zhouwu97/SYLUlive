package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// SchoolAuthorityRetiredMiddleware 在个人学校数据能力退役后于最外层短路请求。
// 该中间件必须放在认证和请求体解析之前，避免旧客户端继续触发鉴权查询或
// 将学号、教务密码等请求体送入后端链路。
func SchoolAuthorityRetiredMiddleware(c *gin.Context) {
	c.AbortWithStatusJSON(http.StatusGone, gin.H{
		"code":  "SCHOOL_AUTHORITY_RETIRED",
		"error": "个人教务数据能力已退役",
	})
}
