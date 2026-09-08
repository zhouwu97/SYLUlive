package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// 冻结期阻断会重新生成学校会话的旧入口，保留清理通道与无持久化身份验证。
func SchoolLegacySecretsFreezeGate(frozen bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		path := strings.TrimRight(c.Request.URL.Path, "/")
		cleanup := c.Request.Method == http.MethodDelete && (path == "/api/edu/bind" || path == "/api/edu/authorization") ||
			c.Request.Method == http.MethodPost && path == "/api/edu/session/logout"
		if frozen && !cleanup && path != "/api/edu/pre_verify" &&
			(path == "/api/edu" || strings.HasPrefix(path, "/api/edu/") || path == "/api/login_edu" || path == "/api/register_with_edu" || path == "/api/password/edu/reset") {
			c.AbortWithStatusJSON(http.StatusGone, gin.H{"code": "SCHOOL_LEGACY_SECRETS_FROZEN", "error": "请升级客户端，在本机连接教务"})
			return
		}
		c.Next()
	}
}

// SchoolAuthorityRetirementGate 在全局幂等、认证和请求体处理中间件之前拦截已退役的学校个人接口。
// 这里只读取开关、HTTP 方法和 URL 路径，不查询数据库，也不读取请求体。
func SchoolAuthorityRetirementGate(retired bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		path := strings.TrimRight(c.Request.URL.Path, "/")
		// 旧认证入口永久停写，不受历史部署开关影响。
		retiredAuth := path == "/api/register_with_edu" || path == "/api/login_edu" || path == "/api/password/edu/reset" || path == "/api/forgot_password"
		// 兼容开关关闭退役时，旧版仍可使用原教务链路；新版只调用独立配置接口。
		identityMutation := c.Request.Method != http.MethodGet && (path == "/api/student-identity" || strings.HasPrefix(path, "/api/student-identity/"))
		if retiredAuth || retired && (identityMutation || isSchoolAuthorityRetiredPath(c.Request.Method, c.Request.URL.Path)) {
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
