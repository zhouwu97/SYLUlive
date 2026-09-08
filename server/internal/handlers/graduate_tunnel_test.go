package handlers

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestGraduateTunnelRestrictsDestinationAndPreservesTLS(t *testing.T) {
	p, err := NewGraduateAcademicIdentityProvider("")
	require.NoError(t, err)
	for _, address := range []string{"example.com:443", "10.0.0.1:443", "127.0.0.1:0", "127.0.0.1:99999"} {
		require.Error(t, p.SetLoopbackTunnel(address))
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer server.Close()
	require.NoError(t, p.SetLoopbackTunnel(server.Listener.Addr().String()))
	transport := p.transport.(*http.Transport)
	defer transport.CloseIdleConnections()
	_, err = transport.DialContext(context.Background(), "tcp", "example.com:443")
	require.Error(t, err)
	connection, err := transport.DialContext(context.Background(), "tcp", "yjsgl.sylu.edu.cn:443")
	require.NoError(t, err)
	require.NoError(t, connection.Close())
	// 本机转发不能让自签名或域名不匹配证书通过学校 HTTPS 验证。
	_, err = p.newClient(nil).Get(defaultGraduateProviderURL)
	require.Error(t, err)
	require.True(t, transport.TLSClientConfig == nil || !transport.TLSClientConfig.InsecureSkipVerify)
	other, err := NewGraduateAcademicIdentityProvider("https://127.0.0.1:8080")
	require.NoError(t, err)
	require.Error(t, other.SetLoopbackTunnel(net.JoinHostPort("127.0.0.1", "18443")))
}
