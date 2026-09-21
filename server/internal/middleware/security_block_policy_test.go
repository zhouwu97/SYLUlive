package middleware

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

type stubSecurityBlockChecker struct {
	blocked    map[string]bool
	err        error
	contextErr error
	seenCtx    []context.Context
	degraded   bool
	calls      int
}

func (s *stubSecurityBlockChecker) IsBlocked(clientIP, route string) (bool, error) {
	s.calls++
	if s.err != nil {
		return false, s.err
	}
	return s.blocked[route], nil
}

func (s *stubSecurityBlockChecker) IsBlockedContext(ctx context.Context, clientIP, route string) (bool, error) {
	s.seenCtx = append(s.seenCtx, ctx)
	if s.contextErr != nil {
		return false, s.contextErr
	}
	return s.IsBlocked(clientIP, route)
}

func (s *stubSecurityBlockChecker) SetSecurityBlockDegraded(value bool) { s.degraded = value }

// SEC-01：实际注册路由与别名必须由同一份策略判断，既无遗漏也无额外扩大。
func TestSensitiveSecurityRouteCoversRegisteredRoutes(t *testing.T) {
	// 必须纳入封禁的路径：取自 cmd/main.go 的实际注册前缀。
	mustCover := []string{
		"/api/login",
		"/api/login_edu",
		"/api/refresh",
		"/api/auth/refresh",
		"/api/register",
		"/api/register/email",
		"/api/register/email/code",
		"/api/forgot_password",
		"/api/password/email/code",
		"/api/password/email/reset",
		"/api/password/edu/reset",
		"/api/change_password",
		"/api/send_code",
		"/api/verify_code",
		"/api/user/email",
		"/api/user/email/code",
		"/api/search",
		"/api/posts",
		"/api/posts/42/replies",
		"/api/messages",
		"/api/feedback",
	}
	for _, path := range mustCover {
		require.True(t, SensitiveSecurityRoute(path), "策略遗漏了应纳入封禁的路由：%s", path)
	}

	// 不得扩大：非 /api 前缀的静态与普通读取不进入封禁查询。
	mustNotCover := []string{
		"/uploads/2026/a.png",
		"/healthz",
		"/api/announcements",
		"/api/canteen/rankings",
		"/api/loginfoo",
		"/api/postscript",
		"/api/searching",
	}
	for _, path := range mustNotCover {
		require.False(t, SensitiveSecurityRoute(path), "策略不应纳入：%s", path)
	}
}

// SEC-02：附加封禁层故障时，仍然必须受原有鉴权与权限限制保护。
func TestSecurityBlockFailOpenKeepsAuthGuards(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{err: errors.New("db down")}
	router.Use(SecurityBlockMiddleware(checker))
	router.Use(func(c *gin.Context) {
		// 模拟真实链路中的账号鉴权：没有令牌一律 401。
		if c.GetHeader("Authorization") == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"code": "authentication_required"})
			return
		}
		c.Next()
	})
	router.POST("/api/posts", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"ok": true}) })

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/posts", nil)
	router.ServeHTTP(recorder, request)

	require.Equal(t, http.StatusUnauthorized, recorder.Code,
		"封禁层 fail-open 不等于跳过鉴权，未登录请求必须仍然被拒")
	require.True(t, checker.degraded, "故障必须反映到健康状态")
}

// SEC-03：查询失败按既有策略 fail-open，故障恢复后可观测地回到正常。
func TestSecurityBlockFailOpenThenRecovery(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{err: errors.New("db down")}
	router.Use(SecurityBlockMiddleware(checker))
	router.GET("/api/search", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"ok": true}) })

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/search?q=x", nil))
	require.Equal(t, http.StatusOK, recorder.Code, "查询失败时附加层 fail-open")
	require.True(t, checker.degraded)

	// 恢复后：不再降级，命中封禁则返回 429。
	checker.err = nil
	checker.blocked = map[string]bool{"/api/search": true}
	recorder = httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/search?q=x", nil))
	require.Equal(t, http.StatusTooManyRequests, recorder.Code)
	require.Equal(t, "security_source_blocked", decodeSecurityCode(t, recorder))
	require.False(t, checker.degraded, "恢复后健康状态必须回到正常")
}

// SEC-05：封禁查询使用请求 context，可被取消，不无界等待。
func TestSecurityBlockPassesRequestContext(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{seenCtx: []context.Context{}}
	router.Use(SecurityBlockMiddleware(checker))
	router.GET("/api/search", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"ok": true}) })

	type ctxKey struct{}
	ctx := context.WithValue(context.Background(), ctxKey{}, "request-scoped")
	request := httptest.NewRequest(http.MethodGet, "/api/search?q=x", nil).WithContext(ctx)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, request)

	require.Len(t, checker.seenCtx, 1)
	require.Equal(t, "request-scoped", checker.seenCtx[0].Value(ctxKey{}),
		"封禁查询必须收到请求 context，客户端中断时才能随之取消")
}

// 未命中策略的路径根本不应触发封禁查询。
func TestSecurityBlockSkipsNonSensitiveRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	checker := &stubSecurityBlockChecker{}
	router.Use(SecurityBlockMiddleware(checker))
	router.GET("/uploads/x.png", func(c *gin.Context) { c.Status(http.StatusOK) })

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/uploads/x.png", nil))
	require.Equal(t, http.StatusOK, recorder.Code)
	require.Zero(t, checker.calls, "非敏感路由不应产生封禁查询")
}

// 未实现 context 能力的 checker 仍需可用（兼容既有实现与测试替身）。
func TestSecurityBlockAcceptsLegacyChecker(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	legacy := &legacySecurityBlockChecker{blocked: true}
	router.Use(SecurityBlockMiddleware(legacy))
	router.GET("/api/search", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"ok": true}) })

	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/search?q=x", nil))
	require.Equal(t, http.StatusTooManyRequests, recorder.Code)
}

type legacySecurityBlockChecker struct{ blocked bool }

func (l *legacySecurityBlockChecker) IsBlocked(clientIP, route string) (bool, error) {
	return l.blocked, nil
}

func decodeSecurityCode(t *testing.T, recorder *httptest.ResponseRecorder) string {
	t.Helper()
	var body map[string]interface{}
	require.NoError(t, json.Unmarshal(recorder.Body.Bytes(), &body))
	code, _ := body["code"].(string)
	return code
}
