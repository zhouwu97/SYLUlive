package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const ContractVersion = "5"

type Backend interface {
	Call(context.Context, string, string, json.RawMessage) (json.RawMessage, error)
}

type HTTPBackend struct {
	BaseURL string
	Client  *http.Client
	Grant   string
}

func (b HTTPBackend) WithGrant(grant string) HTTPBackend {
	b.Grant = strings.TrimSpace(grant)
	return b
}

func (b HTTPBackend) Call(ctx context.Context, capability, grant string, arguments json.RawMessage) (json.RawMessage, error) {
	baseURL := strings.TrimRight(strings.TrimSpace(b.BaseURL), "/")
	if baseURL == "" || strings.TrimSpace(grant) == "" {
		return nil, errors.New("mcp_backend_authorization_required")
	}
	path, ok := capabilityPath(capability)
	if !ok {
		return nil, errors.New("mcp_capability_not_supported")
	}
	client := b.Client
	if client == nil {
		client = http.DefaultClient
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+path, strings.NewReader(string(arguments)))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+grant)
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("mcp_backend_status_%d: %s", response.StatusCode, strings.TrimSpace(string(body)))
	}
	if !json.Valid(body) {
		return nil, errors.New("mcp_backend_invalid_json")
	}
	return body, nil
}

type serverBackend struct {
	backend Backend
	grant   string
}

func (b serverBackend) call(ctx context.Context, capability string, arguments any) (*mcp.CallToolResult, any, error) {
	if b.backend == nil || strings.TrimSpace(b.grant) == "" {
		return errorResult("MCP Grant 缺失"), nil, nil
	}
	raw, err := json.Marshal(arguments)
	if err != nil {
		return errorResult("工具参数无法编码"), nil, nil
	}
	result, err := b.backend.Call(ctx, capability, b.grant, raw)
	if err != nil {
		return errorResult(err.Error()), nil, nil
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(result)}}, StructuredContent: decodeObject(result)}, nil, nil
}

func NewServer(backend Backend, grant string) *mcp.Server {
	server := mcp.NewServer(&mcp.Implementation{Name: "sylulive-pure-capability-plane", Version: ContractVersion}, &mcp.ServerOptions{Instructions: "只提供可核验校园事实和确定性计算；不保存 Agent 状态，不调用 LLM。"})
	b := serverBackend{backend: backend, grant: strings.TrimSpace(grant)}
	addMapTool(server, "system.status", "读取纯能力层契约和健康状态。", b, "system.status")
	addMapTool(server, "policy.search", "检索已发布校园政策和官方通知。", b, "policy.search")
	addMapTool(server, "policy.sources", "读取已发布政策证据来源。", b, "policy.sources")
	addMapTool(server, "competition.search", "检索公开赛事事实。", b, "competition.search")
	addMapTool(server, "competition.details", "读取公开赛事详情事实。", b, "competition.details")
	addMapTool(server, "competition.governed_context", "读取经过治理的赛事候选上下文。", b, "competition.governed_context")
	addMapTool(server, "competition.verify", "核对赛事记录哈希和发布状态。", b, "competition.verify")
	addMapTool(server, "competition.compare", "比较多个赛事的公开确定性事实。", b, "competition.compare")
	addMapTool(server, "academic.summary", "读取当前授权用户的学业摘要。", b, "academic.summary")
	addMapTool(server, "schedule.free_windows", "根据当前授权用户日程计算空闲窗口。", b, "schedule.free_windows")
	addMapTool(server, "schedule.validate_plan", "确定性校验计划是否与已知日程冲突。", b, "schedule.validate_plan")
	return server
}

func addMapTool(server *mcp.Server, name, description string, backend serverBackend, capability string) {
	mcp.AddTool(server, &mcp.Tool{Name: name, Description: description}, func(ctx context.Context, _ *mcp.CallToolRequest, args map[string]any) (*mcp.CallToolResult, any, error) {
		return backend.call(ctx, capability, args)
	})
}

func NewHTTPHandler(backend HTTPBackend) http.Handler {
	return mcp.NewStreamableHTTPHandler(func(request *http.Request) *mcp.Server {
		grant := strings.TrimSpace(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer "))
		return NewServer(backend, grant)
	}, nil)
}

func Run(ctx context.Context, backend HTTPBackend, httpAddr string, stdio bool) error {
	if stdio {
		grant := strings.TrimSpace(os.Getenv("SYLULIVE_MCP_GRANT"))
		if grant == "" {
			return errors.New("stdio transport requires SYLULIVE_MCP_GRANT; prefer streamable HTTP for run-scoped grants")
		}
		return NewServer(backend, grant).Run(ctx, &mcp.StdioTransport{})
	}
	server := &http.Server{Addr: httpAddr, Handler: NewHTTPHandler(backend), ReadHeaderTimeout: 5 * time.Second}
	go func() { <-ctx.Done(); _ = server.Shutdown(context.Background()) }()
	return server.ListenAndServe()
}

func capabilityPath(capability string) (string, bool) {
	paths := map[string]string{
		"system.status":                "/internal/mcp/system/status",
		"policy.search":                "/internal/mcp/policy/search",
		"policy.sources":               "/internal/mcp/policy/sources",
		"competition.search":           "/internal/mcp/competition/search",
		"competition.details":          "/internal/mcp/competition/details",
		"competition.governed_context": "/internal/mcp/competition/candidate-context",
		"competition.verify":           "/internal/mcp/competition/verify-records",
		"competition.compare":          "/internal/mcp/competition/compare",
		"academic.summary":             "/internal/mcp/academic/summary",
		"schedule.free_windows":        "/internal/mcp/schedule/free-windows",
		"schedule.validate_plan":       "/internal/mcp/schedule/validate-plan",
	}
	path, ok := paths[capability]
	return path, ok
}

func errorResult(message string) *mcp.CallToolResult {
	return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: message}}}
}

func decodeObject(raw []byte) any {
	var value map[string]any
	if json.Unmarshal(raw, &value) != nil {
		return map[string]any{"ok": false, "error": map[string]any{"code": "invalid_backend_json"}}
	}
	return value
}
