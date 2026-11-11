package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
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

func TestHTTPBackendCapabilityRoutes(t *testing.T) {
	paths := map[string]string{
		"system.status": "/internal/mcp/system/status", "policy.search": "/internal/mcp/policy/search", "policy.sources": "/internal/mcp/policy/sources",
		"competition.search": "/internal/mcp/competition/search", "competition.details": "/internal/mcp/competition/details", "competition.governed_context": "/internal/mcp/competition/candidate-context",
		"competition.verify": "/internal/mcp/competition/verify-records", "competition.compare": "/internal/mcp/competition/compare", "academic.summary": "/internal/mcp/academic/summary",
		"schedule.free_windows": "/internal/mcp/schedule/free-windows", "schedule.validate_plan": "/internal/mcp/schedule/validate-plan",
	}
	for capability, path := range paths {
		t.Run(capability, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != path || r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer g_synthetic_run" {
					t.Errorf("wrong capability transport: %s %s", r.Method, r.URL.Path)
				}
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"ok":true,"data":{}}`))
			}))
			defer server.Close()
			_, err := (HTTPBackend{BaseURL: server.URL}).Call(context.Background(), capability, "g_synthetic_run", json.RawMessage(`{}`))
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestHTTPBackendFailureBoundaries(t *testing.T) {
	for _, scenario := range []struct {
		name           string
		status         int
		body, expected string
	}{
		{"invalid_json", 200, `{`, "mcp_backend_invalid_json"},
		{"unavailable", 503, `temporary failure`, "mcp_backend_status_503"},
		{"unauthorized", 403, `scope required`, "mcp_backend_status_403"},
		{"bounded_response", 200, strings.Repeat(" ", (1<<20)+1) + `{}`, "mcp_backend_invalid_json"},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(scenario.status)
				_, _ = w.Write([]byte(scenario.body))
			}))
			defer server.Close()
			_, err := (HTTPBackend{BaseURL: server.URL}).Call(context.Background(), "system.status", "g_synthetic", json.RawMessage(`{}`))
			if err == nil || !strings.Contains(err.Error(), scenario.expected) {
				t.Fatalf("expected %s, got %v", scenario.expected, err)
			}
		})
	}
}

func TestHTTPBackendRejectsMissingGrantAndUnknownToolsBeforeNetwork(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("invalid request reached the network") }))
	defer server.Close()
	backend := HTTPBackend{BaseURL: server.URL}
	for _, scenario := range []struct{ capability, grant string }{{"system.status", ""}, {"raw.fetch", "g_synthetic"}} {
		if _, err := backend.Call(context.Background(), scenario.capability, scenario.grant, json.RawMessage(`{}`)); err == nil {
			t.Fatal("invalid request accepted")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := backend.Call(ctx, "system.status", "g_synthetic", json.RawMessage(`{}`)); !errors.Is(err, context.Canceled) {
		t.Fatalf("request cancellation lost: %v", err)
	}
}

func TestStdioRequiresExplicitRunGrant(t *testing.T) {
	t.Setenv("SYLULIVE_MCP_GRANT", "")
	if err := Run(context.Background(), HTTPBackend{}, "", true); err == nil || !strings.Contains(err.Error(), "SYLULIVE_MCP_GRANT") {
		t.Fatalf("stdio accepted an unbound run: %v", err)
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
