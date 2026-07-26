package mcpclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/jsonrpc"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const statusToolName = "hy3_campus_status"

var errProtocolViolation = errors.New("MCP 协议不兼容")

type remoteCallResult struct {
	Payload json.RawMessage
	IsError bool
}

// remoteSession 把 SDK Session 收敛为可测试的协议边界。
// 它不是公开接口，调用方只能使用 ExternalMCPClient。
type remoteSession interface {
	ListTools(context.Context) ([]RemoteToolDefinition, error)
	CallTool(context.Context, string, map[string]interface{}) (remoteCallResult, error)
	Close() error
}

type sessionDialer func(context.Context, Config) (remoteSession, error)

// Client 复用一个 MCP Session，并通过 callMu 把远端调用限制为最大并发 1。
// 任意连接级异常都会丢弃旧 Session，下一次调用再重新 initialize 和 tools/list。
type Client struct {
	config Config
	logger *slog.Logger
	dial   sessionDialer

	callMu    sync.Mutex
	sessionMu sync.Mutex
	session   remoteSession
	healthy   bool
	tools     map[string]RemoteToolDefinition
}

// New 创建一个延迟连接的客户端。连接失败不会在此处阻止主服务启动。
func New(config Config, logger *slog.Logger) (*Client, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Client{
		config: config,
		logger: logger,
		dial:   sdkDial,
		tools:  make(map[string]RemoteToolDefinition),
	}, nil
}

// Connect 建立连接并校验固定的远端工具集合。额外工具只记录，不会暴露给模型。
func (client *Client) Connect(ctx context.Context) error {
	if client == nil || !client.config.Enabled {
		return newError(ErrorDisabled, nil)
	}
	client.callMu.Lock()
	defer client.callMu.Unlock()
	return client.ensureSession(ctx)
}

// ListTools 仅用于健康检查和测试；业务包装工具绝不根据它动态注册模型工具。
func (client *Client) ListTools(ctx context.Context) ([]RemoteToolDefinition, error) {
	if client == nil || !client.config.Enabled {
		return nil, newError(ErrorDisabled, nil)
	}
	client.callMu.Lock()
	defer client.callMu.Unlock()
	if err := client.ensureSession(ctx); err != nil {
		return nil, err
	}
	client.sessionMu.Lock()
	defer client.sessionMu.Unlock()
	result := make([]RemoteToolDefinition, 0, len(client.tools))
	for _, definition := range client.tools {
		result = append(result, definition)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

// CallTool 在单独的硬超时内调用经过 allowlist 和 Schema 校验的工具。
func (client *Client) CallTool(ctx context.Context, name string, arguments map[string]interface{}) (json.RawMessage, error) {
	if client == nil || !client.config.Enabled {
		return nil, newError(ErrorDisabled, nil)
	}
	if _, expected := expectedRemoteToolRequirements[name]; !expected {
		return nil, newError(ErrorToolMissing, nil)
	}
	if arguments == nil {
		arguments = make(map[string]interface{})
	}

	client.callMu.Lock()
	defer client.callMu.Unlock()

	callCtx, cancel := context.WithTimeout(ctx, client.config.ToolTimeout)
	defer cancel()
	if err := client.ensureSession(callCtx); err != nil {
		return nil, err
	}

	client.sessionMu.Lock()
	session := client.session
	_, allowed := client.tools[name]
	client.sessionMu.Unlock()
	if !allowed || session == nil {
		return nil, newError(ErrorToolMissing, nil)
	}

	result, err := session.CallTool(callCtx, name, arguments)
	if err != nil {
		client.invalidateSession()
		return nil, client.classifyCallError(err, callCtx)
	}
	if result.IsError {
		return nil, newError(ErrorInvalidResult, errors.New("远端 MCP 工具返回 IsError"))
	}
	if len(result.Payload) == 0 || len(result.Payload) > MaxResultBytes || !json.Valid(result.Payload) || !isJSONObject(result.Payload) {
		return nil, newError(ErrorInvalidResult, errors.New("远端 MCP 工具结果不是受限 JSON 对象"))
	}
	return append(json.RawMessage(nil), result.Payload...), nil
}

// Healthy 只反映已完成 initialize、tools/list 和固定 Schema 校验的当前 Session。
func (client *Client) Healthy() bool {
	if client == nil {
		return false
	}
	client.sessionMu.Lock()
	defer client.sessionMu.Unlock()
	return client.healthy && client.session != nil
}

// Close 关闭 Session 和关联的 stdio 子进程；它可被多次安全调用。
func (client *Client) Close() error {
	if client == nil {
		return nil
	}
	client.callMu.Lock()
	defer client.callMu.Unlock()
	return client.closeSession()
}

func (client *Client) ensureSession(ctx context.Context) error {
	client.sessionMu.Lock()
	healthy := client.healthy && client.session != nil
	client.sessionMu.Unlock()
	if healthy {
		return nil
	}

	client.invalidateSession()
	session, err := client.dial(ctx, client.config)
	if err != nil {
		return client.classifyCallError(err, ctx)
	}
	definitions, err := session.ListTools(ctx)
	if err != nil {
		_ = session.Close()
		return client.classifyCallError(err, ctx)
	}
	if !hasStatusTool(definitions) {
		_ = session.Close()
		return client.classifyCallError(protocolError("远端缺少状态工具"), ctx)
	}
	validated, missing, extras := validateRemoteTools(definitions)
	for _, name := range extras {
		client.logger.Warn("独立 MCP 返回了未暴露的额外工具", "tool", name)
	}
	if len(missing) > 0 {
		client.logger.Warn("独立 MCP 缺少或不兼容的固定工具", "tools", strings.Join(missing, ","))
	}
	status, err := verifyStatus(ctx, session)
	if err != nil {
		_ = session.Close()
		return client.classifyCallError(err, ctx)
	}
	validated, unavailableByStatus := intersectStatusTools(validated, status.AvailableTools)
	if len(unavailableByStatus) > 0 {
		client.logger.Warn("独立 MCP 状态工具未声明已校验能力", "tools", strings.Join(unavailableByStatus, ","))
	}
	if len(validated) == 0 {
		_ = session.Close()
		return client.classifyCallError(protocolError("远端没有兼容的核心工具"), ctx)
	}
	client.sessionMu.Lock()
	client.session = session
	client.tools = validated
	client.healthy = true
	client.sessionMu.Unlock()
	return nil
}

func (client *Client) invalidateSession() {
	_ = client.closeSession()
}

func (client *Client) closeSession() error {
	client.sessionMu.Lock()
	session := client.session
	client.session = nil
	client.healthy = false
	client.tools = make(map[string]RemoteToolDefinition)
	client.sessionMu.Unlock()
	if session == nil {
		return nil
	}
	return session.Close()
}

func (client *Client) classifyCallError(err error, ctx context.Context) error {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return newError(ErrorTimeout, err)
	}
	if isProtocolError(err) {
		return newError(ErrorProtocol, err)
	}
	if errors.Is(err, mcp.ErrConnectionClosed) || errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled) {
		return newError(ErrorUnavailable, err)
	}
	return newError(ErrorUnavailable, err)
}

type statusResult struct {
	Mode           string   `json:"mode"`
	AvailableTools []string `json:"available_tools"`
}

func verifyStatus(ctx context.Context, session remoteSession) (statusResult, error) {
	result, err := session.CallTool(ctx, statusToolName, map[string]interface{}{})
	if err != nil {
		return statusResult{}, err
	}
	if result.IsError || len(result.Payload) == 0 || len(result.Payload) > MaxResultBytes || !json.Valid(result.Payload) {
		return statusResult{}, protocolError("状态工具返回无效结果")
	}
	var status statusResult
	if err := json.Unmarshal(result.Payload, &status); err != nil ||
		(status.Mode != "disabled" && status.Mode != "fixture" && status.Mode != "live") ||
		!containsString(status.AvailableTools, statusToolName) {
		return statusResult{}, protocolError("状态工具响应不符合约定")
	}
	return status, nil
}

// intersectStatusTools 以状态工具的能力声明作为第二道校验，防止 tools/list 与运行时模式不一致。
func intersectStatusTools(validated map[string]RemoteToolDefinition, available []string) (map[string]RemoteToolDefinition, []string) {
	declared := make(map[string]struct{}, len(available))
	for _, name := range available {
		declared[name] = struct{}{}
	}
	result := make(map[string]RemoteToolDefinition, len(validated))
	missing := make([]string, 0)
	for name, definition := range validated {
		if _, found := declared[name]; found {
			result[name] = definition
			continue
		}
		missing = append(missing, name)
	}
	sort.Strings(missing)
	return result, missing
}

func hasStatusTool(definitions []RemoteToolDefinition) bool {
	for _, definition := range definitions {
		if definition.Name == statusToolName {
			return true
		}
	}
	return false
}

func protocolError(format string, arguments ...interface{}) error {
	return fmt.Errorf("%w: %s", errProtocolViolation, fmt.Sprintf(format, arguments...))
}

func isProtocolError(err error) bool {
	if errors.Is(err, errProtocolViolation) {
		return true
	}
	var rpcError *jsonrpc.Error
	return errors.As(err, &rpcError)
}

type sdkSession struct {
	session *mcp.ClientSession
}

func sdkDial(ctx context.Context, config Config) (remoteSession, error) {
	command, err := commandForConfig(config)
	if err != nil {
		return nil, err
	}
	transport := &mcp.CommandTransport{Command: command, TerminateDuration: 5 * time.Second}
	client := mcp.NewClient(
		&mcp.Implementation{Name: "sylulive-ai-runtime", Version: "1.0.0"},
		&mcp.ClientOptions{Capabilities: &mcp.ClientCapabilities{}},
	)
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		return nil, err
	}
	return &sdkSession{session: session}, nil
}

func commandForConfig(config Config) (*exec.Cmd, error) {
	switch config.Transport {
	case TransportLocalStdio:
		return localCommand(config), nil
	case TransportSSHStdio:
		return sshCommand(config), nil
	default:
		return nil, fmt.Errorf("不支持的 MCP 传输方式")
	}
}

func (session *sdkSession) ListTools(ctx context.Context) ([]RemoteToolDefinition, error) {
	if session == nil || session.session == nil {
		return nil, errors.New("MCP Session 未初始化")
	}
	result := make([]RemoteToolDefinition, 0)
	cursor := ""
	for {
		response, err := session.session.ListTools(ctx, &mcp.ListToolsParams{Cursor: cursor})
		if err != nil {
			return nil, err
		}
		for _, tool := range response.Tools {
			if tool == nil {
				continue
			}
			schema, err := json.Marshal(tool.InputSchema)
			if err != nil {
				return nil, fmt.Errorf("编码远端工具 Schema: %w", err)
			}
			result = append(result, RemoteToolDefinition{Name: tool.Name, Description: tool.Description, InputSchema: schema})
		}
		if response.NextCursor == "" {
			return result, nil
		}
		cursor = response.NextCursor
	}
}

func (session *sdkSession) CallTool(ctx context.Context, name string, arguments map[string]interface{}) (remoteCallResult, error) {
	if session == nil || session.session == nil {
		return remoteCallResult{}, errors.New("MCP Session 未初始化")
	}
	result, err := session.session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: arguments})
	if err != nil {
		return remoteCallResult{}, err
	}
	payload, err := extractPayload(result)
	if err != nil {
		return remoteCallResult{}, err
	}
	return remoteCallResult{Payload: payload, IsError: result.IsError}, nil
}

func (session *sdkSession) Close() error {
	if session == nil || session.session == nil {
		return nil
	}
	return session.session.Close()
}

func extractPayload(result *mcp.CallToolResult) (json.RawMessage, error) {
	if result == nil {
		return nil, errors.New("MCP 返回空工具结果")
	}
	if result.StructuredContent != nil {
		payload, err := json.Marshal(result.StructuredContent)
		if err != nil {
			return nil, err
		}
		return payload, nil
	}
	for _, content := range result.Content {
		text, ok := content.(*mcp.TextContent)
		if !ok {
			continue
		}
		return json.RawMessage(text.Text), nil
	}
	return nil, errors.New("MCP 工具结果缺少结构化 JSON")
}

type schemaRequirement struct {
	Properties []string
	Required   []string
}

var expectedRemoteToolRequirements = map[string]schemaRequirement{
	"compare_competitions": {
		Properties: []string{"student_profile", "competition_names", "competitions"},
		Required:   []string{"student_profile"},
	},
	"analyze_academic_snapshot": {
		Properties: []string{"snapshot", "snapshot_path"},
	},
	"plan_student_week": {
		Properties: []string{"schedule", "schedule_path", "goals", "constraints"},
	},
}

func validateRemoteTools(definitions []RemoteToolDefinition) (map[string]RemoteToolDefinition, []string, []string) {
	byName := make(map[string]RemoteToolDefinition, len(definitions))
	for _, definition := range definitions {
		if strings.TrimSpace(definition.Name) != "" {
			byName[definition.Name] = definition
		}
	}
	validated := make(map[string]RemoteToolDefinition, len(expectedRemoteToolRequirements))
	missing := make([]string, 0)
	for name, requirement := range expectedRemoteToolRequirements {
		definition, found := byName[name]
		if !found || !schemaMatches(definition.InputSchema, requirement) {
			missing = append(missing, name)
			continue
		}
		validated[name] = definition
	}
	extras := make([]string, 0)
	for name := range byName {
		if name == statusToolName {
			continue
		}
		if _, expected := expectedRemoteToolRequirements[name]; !expected {
			extras = append(extras, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(extras)
	return validated, missing, extras
}

func schemaMatches(raw json.RawMessage, requirement schemaRequirement) bool {
	var schema struct {
		Type                 string                     `json:"type"`
		Properties           map[string]json.RawMessage `json:"properties"`
		Required             []string                   `json:"required"`
		AdditionalProperties *bool                      `json:"additionalProperties"`
	}
	if len(raw) == 0 || json.Unmarshal(raw, &schema) != nil || schema.Type != "object" || len(schema.Properties) != len(requirement.Properties) || schema.AdditionalProperties == nil || *schema.AdditionalProperties {
		return false
	}
	for _, property := range requirement.Properties {
		if _, found := schema.Properties[property]; !found {
			return false
		}
	}
	for _, required := range requirement.Required {
		if !containsString(schema.Required, required) {
			return false
		}
	}
	return true
}

func containsString(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func isJSONObject(raw json.RawMessage) bool {
	var value map[string]interface{}
	return json.Unmarshal(raw, &value) == nil && value != nil
}
