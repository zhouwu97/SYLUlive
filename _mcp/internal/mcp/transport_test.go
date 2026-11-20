package mcpserver

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type grantTransport struct {
	grant   string
	session atomic.Value
}

func (transport *grantTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	copy := request.Clone(request.Context())
	copy.Header.Set("Authorization", "Bearer "+transport.grant)
	response, err := http.DefaultTransport.RoundTrip(copy)
	if err == nil && response.Header.Get("Mcp-Session-Id") != "" {
		transport.session.Store(response.Header.Get("Mcp-Session-Id"))
	}
	return response, err
}

func connectClient(t *testing.T, ctx context.Context, transport mcp.Transport) *mcp.ClientSession {
	t.Helper()
	client := mcp.NewClient(&mcp.Implementation{Name: "lifecycle-test", Version: "1"}, nil)
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	tools, err := session.ListTools(ctx, &mcp.ListToolsParams{})
	if err != nil || len(tools.Tools) != 11 {
		t.Fatalf("tools: %v, %v", tools, err)
	}
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "system.status", Arguments: map[string]any{}})
	if err != nil || result.IsError {
		t.Fatalf("call: %v, %v", result, err)
	}
	return session
}

func TestHTTPTransportInitializeCallCloseReconnectAndGrantIsolation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var calls atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/internal/mcp/system/status" {
			t.Errorf("unexpected capability route")
		}
		if value := r.Header.Get("Authorization"); value != "Bearer g_first" && value != "Bearer g_second" {
			t.Errorf("missing per-run grant")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer backend.Close()
	gateway := httptest.NewServer(NewHTTPHandler(HTTPBackend{BaseURL: backend.URL}))
	defer gateway.Close()
	headers := &grantTransport{grant: "g_first"}
	session := connectClient(t, ctx, &mcp.StreamableClientTransport{Endpoint: gateway.URL, HTTPClient: &http.Client{Transport: headers}})
	defer session.Close()
	id, _ := headers.session.Load().(string)
	if id == "" {
		t.Fatal("initialized HTTP session has no id")
	}
	for _, method := range []string{http.MethodPost, http.MethodGet, http.MethodDelete} {
		for _, grant := range []string{"", "g_second"} {
			request, err := http.NewRequestWithContext(ctx, method, gateway.URL, strings.NewReader(`{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"system.status","arguments":{}}}`))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Mcp-Session-Id", id)
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Accept", "application/json, text/event-stream")
			request.Header.Set("MCP-Protocol-Version", "2025-06-18")
			if grant != "" {
				request.Header.Set("Authorization", "Bearer "+grant)
			}
			response, err := http.DefaultClient.Do(request)
			if err != nil {
				t.Fatal(err)
			}
			_ = response.Body.Close()
			expected := http.StatusForbidden
			if grant == "" {
				expected = http.StatusUnauthorized
			}
			if response.StatusCode != expected {
				t.Fatalf("%s wrong grant status=%d, expected=%d", method, response.StatusCode, expected)
			}
		}
	}
	if calls.Load() != 1 {
		t.Fatal("unauthorized session reuse reached backend")
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if err := session.Close(); err != nil {
		t.Fatal("close is not idempotent", err)
	}
	second := connectClient(t, ctx, &mcp.StreamableClientTransport{Endpoint: gateway.URL, HTTPClient: &http.Client{Transport: &grantTransport{grant: "g_second"}}})
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatalf("reconnect calls=%d", calls.Load())
	}
}

func TestStdioTransportInitializeCallCloseReconnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	var calls atomic.Int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") != "Bearer g_stdio_fixture" {
			t.Error("stdio lost run grant")
		}
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer backend.Close()
	for i := 0; i < 2; i++ {
		command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStdioTransportHelperProcess$")
		command.Env = append(os.Environ(), "SYLULIVE_MCP_STDIO_TEST=1", "SYLULIVE_MCP_STDIO_BACKEND="+backend.URL, "SYLULIVE_MCP_GRANT=g_stdio_fixture")
		session := connectClient(t, ctx, &mcp.CommandTransport{Command: command, TerminateDuration: 5 * time.Second})
		if err := session.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if calls.Load() != 2 {
		t.Fatalf("stdio reconnect calls=%d", calls.Load())
	}
}

func TestStdioTransportHelperProcess(t *testing.T) {
	if os.Getenv("SYLULIVE_MCP_STDIO_TEST") != "1" {
		return
	}
	if err := Run(context.Background(), HTTPBackend{BaseURL: os.Getenv("SYLULIVE_MCP_STDIO_BACKEND")}, "", true); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "stdio helper failed")
		os.Exit(1)
	}
	os.Exit(0)
}
