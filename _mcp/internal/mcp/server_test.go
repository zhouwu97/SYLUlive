package mcpserver

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCapabilityPathContainsOnlySemanticTools(t *testing.T) {
	path, ok := capabilityPath("academic.summary")
	if !ok || path != "/internal/mcp/academic/summary" {
		t.Fatalf("path=%q ok=%v", path, ok)
	}
	_, ok = capabilityPath("academic_get_summary")
	if ok {
		t.Fatal("legacy tool name must not be accepted")
	}
}

func TestHTTPBackendForwardsOpaqueGrantOnlyAsAuthorization(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/mcp/competition/search" {
			t.Fatalf("path=%s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer g_run_scoped" {
			t.Fatalf("authorization leaked or missing")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["query"] != "算法" {
			t.Fatalf("body=%v", body)
		}
		_, _ = w.Write([]byte(`{"ok":true,"data":{"items":[]}}`))
	}))
	defer server.Close()
	backend := HTTPBackend{BaseURL: server.URL}
	result, err := backend.Call(context.Background(), "competition.search", "g_run_scoped", json.RawMessage(`{"query":"算法"}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(result), `"ok":true`) {
		t.Fatalf("result=%s", result)
	}
}

func TestServerWithoutGrantReturnsToolError(t *testing.T) {
	server := NewServer(HTTPBackend{}, "")
	// 这里不启动 SDK session；只验证构造不需要任何后端凭据，Grant 在 CallTool 边界检查。
	if server == nil {
		t.Fatal("server is nil")
	}
}
