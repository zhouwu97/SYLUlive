package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestReadAbuseRateLimitMiddlewareLimitsReadRouteByClientIP(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(ReadAbuseRateLimitMiddleware(2, time.Minute, "/api/posts"))
	router.GET("/api/posts", func(c *gin.Context) { c.Status(http.StatusOK) })

	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodGet, "/api/posts", nil)
		req.RemoteAddr = "192.0.2.10:1234"
		resp := httptest.NewRecorder()
		router.ServeHTTP(resp, req)
		require.Equal(t, http.StatusOK, resp.Code)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/posts/1", nil)
	req.RemoteAddr = "192.0.2.10:1234"
	resp := httptest.NewRecorder()
	router.ServeHTTP(resp, req)
	require.Equal(t, http.StatusTooManyRequests, resp.Code)
	require.Equal(t, "60", resp.Header().Get("Retry-After"))
	require.Contains(t, resp.Body.String(), "read_rate_limited")
}

func TestReadAbuseRateLimitMiddlewareDoesNotLimitWritesOrOtherRoutes(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.Use(ReadAbuseRateLimitMiddleware(1, time.Minute, "/api/posts"))
	router.GET("/api/posts", func(c *gin.Context) { c.Status(http.StatusOK) })
	router.POST("/api/posts", func(c *gin.Context) { c.Status(http.StatusCreated) })
	router.GET("/api/profile", func(c *gin.Context) { c.Status(http.StatusOK) })

	for _, methodPath := range []struct {
		method string
		path   string
		status int
	}{
		{http.MethodPost, "/api/posts", http.StatusCreated},
		{http.MethodGet, "/api/profile", http.StatusOK},
		{http.MethodGet, "/api/posts", http.StatusOK},
	} {
		req := httptest.NewRequest(methodPath.method, methodPath.path, nil)
		req.RemoteAddr = "192.0.2.11:1234"
		resp := httptest.NewRecorder()
		router.ServeHTTP(resp, req)
		require.Equal(t, methodPath.status, resp.Code)
	}
}
