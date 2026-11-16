package handlers

import (
	"context"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

// 显式本机联调：真实 Web 密钥、Flutter 加密/HTTP、Go 内存中转和网页导入。
func TestAcademicTransferWebAppChain(t *testing.T) {
	web := os.Getenv("QR_CHAIN_WEB")
	if web == "" || os.Getenv("QR_CHAIN_FLUTTER") == "" {
		t.Skip("set QR_CHAIN_WEB to a loopback Web preview and QR_CHAIN_FLUTTER to the Flutter executable")
	}
	upstream, err := url.Parse(web)
	require.NoError(t, err)
	require.Equal(t, "http", upstream.Scheme)
	require.Equal(t, "127.0.0.1", upstream.Hostname())
	gin.SetMode(gin.TestMode)
	r := gin.New()
	h := NewAcademicTransferHandler()
	api := r.Group("/api/academic-transfer", func(c *gin.Context) { c.Set("user_id", uint(7)) })
	api.POST("/sessions", h.Create)
	api.GET("/sessions/:id", h.Get)
	api.POST("/sessions/:id/claim", h.Claim)
	api.PUT("/sessions/:id/payload", h.Upload)
	api.DELETE("/sessions/:id", h.Delete)
	proxy := httputil.NewSingleHostReverseProxy(upstream)
	r.NoRoute(func(c *gin.Context) {
		if strings.HasPrefix(c.Request.URL.Path, "/web/") {
			proxy.ServeHTTP(c.Writer, c.Request)
			return
		}
		c.Status(404)
	})
	server := httptest.NewServer(r)
	defer server.Close()
	root, err := filepath.Abs("../../..")
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "node", filepath.Join(root, "scripts/verify-academic-transfer-chain.mjs"))
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "QR_CHAIN_ORIGIN="+server.URL)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "%s", out)
	t.Log(string(out))
	h.mu.Lock()
	defer h.mu.Unlock()
	require.Empty(t, h.sessions, "网页解密后须确认清除服务端密文")
	require.Zero(t, h.totalBytes)
}
