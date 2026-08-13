package mcpclient

import (
	"context"
	"crypto/sha256"
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

	callMu            sync.Mutex
	sessionMu         sync.Mutex
	session           remoteSession
	healthy           bool
	healthStatus      ExternalMCPHealthStatus
	tools             map[string]RemoteToolDefinition
	lastProtocolError error
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
	client.sessionMu.Lock()
	lastProtocolError := client.lastProtocolError
	client.sessionMu.Unlock()
	if lastProtocolError != nil {
		return nil, lastProtocolError
	}
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
	if _, expected := expectedRemoteToolContracts[name]; !expected {
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

// HealthStatus 返回当前已验证 Session 的安全状态，不包含传输或 Provider 配置。
func (client *Client) HealthStatus() ExternalMCPHealthStatus {
	if client == nil {
		return ExternalMCPHealthStatus{}
	}
	client.sessionMu.Lock()
	defer client.sessionMu.Unlock()
	if !client.healthy || client.session == nil {
		return ExternalMCPHealthStatus{}
	}
	return client.healthStatus
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
	status, err := verifyStatus(ctx, session)
	if err != nil {
		_ = session.Close()
		return client.classifyCallError(err, ctx)
	}
	validated, missing, extras := validateRemoteTools(definitions, status)
	for _, name := range extras {
		client.logger.Warn("独立 MCP 返回了未暴露的额外工具", "tool", name)
	}
	if len(missing) > 0 {
		client.logger.Warn("独立 MCP 缺少或不兼容的固定工具", "tools", strings.Join(missing, ","))
	}
	if len(validated) == 0 {
		_ = session.Close()
		err := client.classifyCallError(protocolError("远端没有兼容的核心工具"), ctx)
		client.sessionMu.Lock()
		client.lastProtocolError = err
		client.sessionMu.Unlock()
		return err
	}
	client.sessionMu.Lock()
	client.session = session
	client.tools = validated
	client.healthy = true
	client.healthStatus = ExternalMCPHealthStatus{
		Healthy: true, Mode: status.Mode, ContractVersion: status.ContractVersion,
		AvailableTools: len(validated),
	}
	client.lastProtocolError = nil
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
	client.healthStatus = ExternalMCPHealthStatus{}
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
	Mode            string                          `json:"mode"`
	ContractVersion string                          `json:"contract_version"`
	AvailableTools  []string                        `json:"available_tools"`
	ToolContracts   map[string]remoteContractStatus `json:"tool_contracts"`
}

type remoteContractStatus struct {
	SchemaSHA256 string `json:"schema_sha256"`
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
		status.ContractVersion != expectedRemoteContractVersion ||
		!containsString(status.AvailableTools, statusToolName) {
		return statusResult{}, protocolError("状态工具响应不符合约定")
	}
	return status, nil
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
			inputSchema, err := json.Marshal(tool.InputSchema)
			if err != nil {
				return nil, fmt.Errorf("编码远端工具输入 Schema: %w", err)
			}
			outputSchema, err := json.Marshal(tool.OutputSchema)
			if err != nil {
				return nil, fmt.Errorf("编码远端工具输出 Schema: %w", err)
			}
			result = append(result, RemoteToolDefinition{
				Name: tool.Name, Description: tool.Description, InputSchema: inputSchema, OutputSchema: outputSchema,
			})
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

const expectedRemoteContractVersion = "sylulive-hy3/2"

var expectedRemoteToolContracts = map[string]string{
	"compare_competitions":           "183668200d82156e6385342d747d229e5ab8fe49ba4351afaf8fccc9c896905c",
	"explain_competition_candidates": "869bed351400771f7272b5c05b97d2c20875c7ddff0db65cb9d064b5c1f84721",
	"compare_selected_competitions":  "b8e151f2e964f96dcbc5d533632da63f5adf9b7106f681d861edb7f05cc0b463",
	"analyze_academic_snapshot":      "61e7fa7dec52c493305fb585d9c44aa6c8329a716c4b29359f3a480621898269",
	"plan_student_week":              "0cb4a9c774ea6799b8f95945d89c21195c0cb228315ab73fd849259814cc7518",
}

var allowedAuxiliaryRemoteTools = map[string]struct{}{
	"answer_campus_question": {},
}

func validateRemoteTools(definitions []RemoteToolDefinition, status statusResult) (map[string]RemoteToolDefinition, []string, []string) {
	byName := make(map[string]RemoteToolDefinition, len(definitions))
	for _, definition := range definitions {
		if strings.TrimSpace(definition.Name) != "" {
			byName[definition.Name] = definition
		}
	}
	validated := make(map[string]RemoteToolDefinition, len(expectedRemoteToolContracts))
	missing := make([]string, 0)
	for name, expectedDigest := range expectedRemoteToolContracts {
		definition, found := byName[name]
		declared, available := status.ToolContracts[name]
		actualDigest, digestErr := schemaDigest(definition.InputSchema, definition.OutputSchema)
		if !found || !containsString(status.AvailableTools, name) || !available ||
			digestErr != nil || declared.SchemaSHA256 == "" ||
			declared.SchemaSHA256 != actualDigest || actualDigest != expectedDigest {
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
		if _, allowed := allowedAuxiliaryRemoteTools[name]; allowed {
			continue
		}
		if _, expected := expectedRemoteToolContracts[name]; !expected {
			extras = append(extras, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(extras)
	return validated, missing, extras
}

func schemaDigest(inputSchema, outputSchema json.RawMessage) (string, error) {
	var input, output interface{}
	if len(inputSchema) == 0 || len(outputSchema) == 0 ||
		json.Unmarshal(inputSchema, &input) != nil || json.Unmarshal(outputSchema, &output) != nil {
		return "", errors.New("远端工具缺少有效的输入或输出 Schema")
	}
	normalized, err := json.Marshal(map[string]interface{}{
		"input_schema":  normalizeSchema(input),
		"output_schema": normalizeSchema(output),
	})
	if err != nil {
		return "", fmt.Errorf("规范化远端 Schema: %w", err)
	}
	digest := sha256.Sum256(normalized)
	return fmt.Sprintf("%x", digest), nil
}

func normalizeSchema(value interface{}) interface{} {
	switch typed := value.(type) {
	case map[string]interface{}:
		result := make(map[string]interface{}, len(typed))
		for key, child := range typed {
			switch key {
			case "title", "description", "examples":
				continue
			default:
				result[key] = normalizeSchema(child)
			}
		}
		return result
	case []interface{}:
		result := make([]interface{}, len(typed))
		for index, child := range typed {
			result[index] = normalizeSchema(child)
		}
		return result
	default:
		return value
	}
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
