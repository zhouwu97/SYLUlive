package mcpclient

import (
	"context"
	"encoding/json"
)

// RemoteToolDefinition 是 tools/list 的最小安全视图。输入 Schema 仅用于本地兼容性校验。
type RemoteToolDefinition struct {
	Name        string
	Description string
	InputSchema json.RawMessage
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
