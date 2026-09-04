package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// SchoolAuthorityRetirementGate 在全局幂等、认证和请求体处理中间件之前拦截已退役的学校个人接口。
// 这里只读取开关、HTTP 方法和 URL 路径，不查询数据库，也不读取请求体。
func SchoolAuthorityRetirementGate(retired bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		if retired && isSchoolAuthorityRetiredPath(c.Request.Method, c.Request.URL.Path) {
			SchoolAuthorityRetiredMiddleware(c)
			return
		}
		c.Next()
	}
}

func isSchoolAuthorityRetiredPath(method, path string) bool {
	_ = method // 路由范围本身已经限定为学校个人能力，保留方法参数以明确不读取请求体或认证状态。
	path = strings.TrimRight(path, "/")
	if path == "" {
		path = "/"
	}
	if path == "/api/edu" || strings.HasPrefix(path, "/api/edu/") {
		return true
	}
	switch path {
	case "/api/erke/scores", "/api/personal-snapshots/erke",
		"/api/register_with_edu", "/api/forgot_password",
		"/api/password/edu/reset", "/api/login_edu":
		return true
	default:
		return false
	}
}

// SchoolAuthorityRetiredMiddleware 在个人学校数据能力退役后于最外层短路请求。
// 该中间件必须放在认证和请求体解析之前，避免旧客户端继续触发鉴权查询或
// 将学号、教务密码等请求体送入后端链路。
func SchoolAuthorityRetiredMiddleware(c *gin.Context) {
	c.AbortWithStatusJSON(http.StatusGone, gin.H{
		"code":  "SCHOOL_AUTHORITY_RETIRED",
		"error": "个人教务数据能力已退役",
	})
}
