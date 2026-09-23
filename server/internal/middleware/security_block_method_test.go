package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

// 普通读取不再进入封禁查询：这一层挂在鉴权之前，读请求每次进来都先打一次
// security_blocks 的话，防攻击层自己就成了数据库放大面。
func TestSecurityBlockSkipsReadOnlyContentRequests(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{blocked: map[string]bool{"*": true}}
	router.Use(SecurityBlockMiddleware(checker))
	for _, route := range []string{"/api/posts", "/api/search", "/api/messages", "/api/feedback", "/api/feedback/tickets/:id"} {
		route := route
		router.GET(route, func(c *gin.Context) { c.Status(http.StatusOK) })
	}

	for _, path := range []string{"/api/posts", "/api/search?q=x", "/api/messages", "/api/feedback/tickets/1"} {
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		require.Equal(t, http.StatusOK, recorder.Code, "GET %s 不应被来源封禁拦下", path)
	}
	require.Zero(t, checker.calls, "内容读取不应在鉴权前查封禁表")
}

// 同一批前缀上的写方法必须仍然进入封禁查询。
func TestSecurityBlockStillCoversContentWrites(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{}
	router.Use(SecurityBlockMiddleware(checker))
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		method := method
		router.Handle(method, "/api/posts", func(c *gin.Context) { c.Status(http.StatusOK) })
	}

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		recorder := httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest(method, "/api/posts", nil))
		require.Equal(t, http.StatusOK, recorder.Code)
	}
	require.Equal(t, 4, checker.calls, "内容写入的每个写方法都要查封禁表")
}

// 账号凭据组不限方法：GET 形态的探测同样要受限。
func TestSecurityBlockKeepsCredentialRoutesMethodAgnostic(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{blocked: map[string]bool{"/api/login": true}}
	router.Use(SecurityBlockMiddleware(checker))
	router.GET("/api/login", func(c *gin.Context) { c.Status(http.StatusOK) })

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/login", nil))
	require.Equal(t, http.StatusTooManyRequests, recorder.Code)
	require.Equal(t, 1, checker.calls)
}

// 请求级策略必须能被登记表推出：内容组只认写方法，凭据组不限方法。
// 两件事都只允许有一个事实来源，否则界面说明会和真正生效的过滤器分叉。
func TestSensitiveSecurityRouteForSeparatesReadFromWrite(t *testing.T) {
	contentPaths := []string{"/api/search", "/api/posts", "/api/posts/42/replies", "/api/messages", "/api/feedback"}
	for _, path := range contentPaths {
		for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
			require.True(t, SensitiveSecurityRouteFor(method, path), "写方法 %s %s 必须进入封禁查询", method, path)
		}
		for _, method := range []string{http.MethodGet, http.MethodHead, http.MethodOptions} {
			require.False(t, SensitiveSecurityRouteFor(method, path), "读方法 %s %s 不应进入封禁查询", method, path)
		}
		require.True(t, SensitiveSecurityRoute(path), "路径登记事实不随方法变化：%s", path)
	}
	credentialPaths := []string{"/api/login", "/api/send_code", "/api/change_password", "/api/refresh"}
	for _, path := range credentialPaths {
		for _, method := range []string{http.MethodGet, http.MethodPost} {
			require.True(t, SensitiveSecurityRouteFor(method, path), "凭据组必须不限方法：%s %s", method, path)
		}
	}
}

// 登记的方法策略必须和请求级过滤器一致，不能出现「表里写了 POST、过滤器却放行 GET」。
func TestSecurityRouteGroupMethodsMatchRequestGate(t *testing.T) {
	methods := []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodHead, http.MethodOptions}
	for _, group := range securityRouteGroups {
		for _, prefix := range group.Prefixes {
			for _, method := range methods {
				want := group.AllowsMethod(method)
				require.Equal(t, want, SensitiveSecurityRouteFor(method, prefix),
					"分组 %s 前缀 %s 方法 %s 的登记策略与请求级过滤器不一致", group.ID, prefix, method)
			}
		}
	}
}
