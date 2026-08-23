package ai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// MCPV5Gateway 是 Go Agent Runtime 到纯能力 MCP 的唯一客户端入口。
// 每次调用都用当前 Run 的 Grant 建立短生命周期 MCP Session，避免跨 Run 复用 subject。
type MCPV5Gateway struct {
	endpoint string
	client   *http.Client
}

func NewMCPV5Gateway(endpoint string, client *http.Client) (*MCPV5Gateway, error) {
	endpoint = strings.TrimSpace(endpoint)
	if endpoint == "" {
		return nil, errors.New("mcp_v5_endpoint_required")
	}
	if !strings.HasPrefix(endpoint, "http://") && !strings.HasPrefix(endpoint, "https://") {
		return nil, errors.New("mcp_v5_endpoint_invalid")
	}
	if client == nil {
		client = http.DefaultClient
	}
	return &MCPV5Gateway{endpoint: endpoint, client: client}, nil
}

// CallTool 只接收语义能力名和 Grant；arguments 不允许携带身份字段。
func (g *MCPV5Gateway) CallTool(ctx context.Context, grant, capability string, arguments json.RawMessage) (ToolResultEnvelope, error) {
	if g == nil || g.endpoint == "" || strings.TrimSpace(grant) == "" {
		return ToolResultEnvelope{}, errors.New("mcp_v5_grant_required")
	}
	if _, ok := mcpV5CapabilityNames[capability]; !ok {
		return ToolResultEnvelope{}, errors.New("mcp_v5_capability_not_supported")
	}
	if len(arguments) == 0 {
		arguments = json.RawMessage(`{}`)
	}
	if len(arguments) > 16<<10 || !json.Valid(arguments) || containsForbiddenToolIdentity(arguments) {
		return ToolResultEnvelope{}, errors.New("mcp_v5_arguments_invalid")
	}
	var args map[string]interface{}
	if err := json.Unmarshal(arguments, &args); err != nil || args == nil {
		return ToolResultEnvelope{}, errors.New("mcp_v5_arguments_object_required")
	}

	transport := &mcp.StreamableClientTransport{
		Endpoint:   g.endpoint,
		HTTPClient: &http.Client{Transport: bearerRoundTripper{base: g.client.Transport, grant: grant}, Timeout: g.client.Timeout},
		MaxRetries: 0,
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "sylulive-agent-runtime", Version: AgentContractVersion}, &mcp.ClientOptions{Capabilities: &mcp.ClientCapabilities{}})
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		return ToolResultEnvelope{}, classifyMCPV5Error("mcp_v5_connect", err, ctx)
	}
	defer session.Close()
	result, err := session.CallTool(ctx, &mcp.CallToolParams{Name: capability, Arguments: args})
	if err != nil {
		return ToolResultEnvelope{}, classifyMCPV5Error("mcp_v5_call", err, ctx)
	}
	raw, err := mcpV5ResultJSON(result)
	if err != nil {
		return ToolResultEnvelope{}, err
	}
	envelope, err := DecodeToolResult(raw)
	if err != nil {
		return ToolResultEnvelope{}, err
	}
	if result.IsError && envelope.OK {
		envelope.OK = false
		envelope.Error = &ToolError{Code: "mcp_tool_error", Message: "纯能力 MCP 返回工具错误", Retryable: true}
	}
	return envelope, nil
}

func classifyMCPV5Error(prefix string, err error, ctx context.Context) error {
	if ctx != nil && ctx.Err() != nil {
		return fmt.Errorf("%s_timeout: %w", prefix, ctx.Err())
	}
	return fmt.Errorf("%s_unavailable: %w", prefix, err)
}

type bearerRoundTripper struct {
	base  http.RoundTripper
	grant string
}

func (t bearerRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	base := t.base
	if base == nil {
		base = http.DefaultTransport
	}
	cloned := request.Clone(request.Context())
	cloned.Header.Set("Authorization", "Bearer "+strings.TrimSpace(t.grant))
	return base.RoundTrip(cloned)
}

func mcpV5ResultJSON(result *mcp.CallToolResult) (json.RawMessage, error) {
	if result == nil {
		return nil, errors.New("mcp_v5_empty_result")
	}
	if result.StructuredContent != nil {
		raw, err := json.Marshal(result.StructuredContent)
		if err != nil {
			return nil, fmt.Errorf("mcp_v5_result_encode: %w", err)
		}
		return raw, nil
	}
	for _, content := range result.Content {
		text, ok := content.(*mcp.TextContent)
		if ok && json.Valid([]byte(text.Text)) {
			return json.RawMessage(text.Text), nil
		}
	}
	return nil, errors.New("mcp_v5_result_json_required")
}

var mcpV5CapabilityNames = map[string]struct{}{
	"system.status": {}, "policy.search": {}, "policy.sources": {},
	"competition.search": {}, "competition.details": {}, "competition.governed_context": {},
	"competition.verify": {}, "competition.compare": {}, "academic.summary": {},
	"schedule.free_windows": {}, "schedule.validate_plan": {},
}
