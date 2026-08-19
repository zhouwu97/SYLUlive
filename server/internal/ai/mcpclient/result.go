package mcpclient

import (
	"context"
	"encoding/json"
)

// RemoteToolDefinition 是 tools/list 的最小安全视图。输入和输出 Schema 均参与契约校验。
type RemoteToolDefinition struct {
	Name         string
	Description  string
	InputSchema  json.RawMessage
	OutputSchema json.RawMessage
}

// ExternalMCPHealthStatus 是通过状态工具和固定 Schema 校验后的安全诊断视图。
type ExternalMCPHealthStatus struct {
	Healthy         bool
	Mode            string
	ContractVersion string
	AvailableTools  int
}

// ExternalMCPClient 是业务包装工具所依赖的稳定接口。
// 业务层不会直接接触 MCP SDK Session 或子进程对象。
type ExternalMCPClient interface {
	Connect(ctx context.Context) error
	ListTools(ctx context.Context) ([]RemoteToolDefinition, error)
	CallTool(ctx context.Context, name string, arguments map[string]interface{}) (json.RawMessage, error)
	Healthy() bool
	Close() error
}
