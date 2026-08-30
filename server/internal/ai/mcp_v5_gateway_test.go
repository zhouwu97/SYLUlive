package ai

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/stretchr/testify/require"
)

func TestNewMCPV5GatewayValidatesEndpoint(t *testing.T) {
	_, err := NewMCPV5Gateway("file:///tmp/mcp", nil)
	require.ErrorContains(t, err, "mcp_v5_endpoint_invalid")
	gateway, err := NewMCPV5Gateway("http://127.0.0.1:8091", nil)
	require.NoError(t, err)
	require.NotNil(t, gateway)
}

func TestMCPV5BearerRoundTripperInjectsOpaqueGrant(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		require.Equal(t, "Bearer g_test", request.Header.Get("Authorization"))
		writer.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL, nil)
	require.NoError(t, err)
	response, err := (bearerRoundTripper{grant: "g_test"}).RoundTrip(request)
	require.NoError(t, err)
	defer response.Body.Close()
}

func TestMCPV5ResultJSONPrefersStructuredEnvelope(t *testing.T) {
	result := &mcp.CallToolResult{StructuredContent: map[string]interface{}{"ok": true, "data": map[string]interface{}{"value": 1}}}
	raw, err := mcpV5ResultJSON(result)
	require.NoError(t, err)
	var envelope ToolResultEnvelope
	require.NoError(t, json.Unmarshal(raw, &envelope))
	require.True(t, envelope.OK)

	textResult := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: `{"ok":true}`}}}
	raw, err = mcpV5ResultJSON(textResult)
	require.NoError(t, err)
	require.Equal(t, `{"ok":true}`, string(raw))
}
