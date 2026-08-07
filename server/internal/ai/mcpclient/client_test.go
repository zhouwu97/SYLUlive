package mcpclient

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

var productionExpectedRemoteToolContracts = cloneContractDigests(expectedRemoteToolContracts)

func TestMain(m *testing.M) {
	// 单元测试使用最小 Schema；生产固定摘要仍由跨进程测试覆盖。
	definitions := compatibleDefinitions()
	contracts := make(map[string]string)
	for _, definition := range definitions {
		if definition.Name == statusToolName {
			continue
		}
		digest, err := schemaDigest(definition.InputSchema, definition.OutputSchema)
		if err != nil {
			panic(err)
		}
		contracts[definition.Name] = digest
	}
	expectedRemoteToolContracts = contracts
	os.Exit(m.Run())
}

func cloneContractDigests(source map[string]string) map[string]string {
	result := make(map[string]string, len(source))
	for name, digest := range source {
		result[name] = digest
	}
	return result
}

type fakeRemoteSession struct {
	definitions []RemoteToolDefinition
	listErr     error
	status      remoteCallResult
	callFn      func(context.Context, string, map[string]interface{}) (remoteCallResult, error)
	calls       []string
	closed      int
}

func (session *fakeRemoteSession) ListTools(context.Context) ([]RemoteToolDefinition, error) {
	if session.listErr != nil {
		return nil, session.listErr
	}
	return append([]RemoteToolDefinition(nil), session.definitions...), nil
}

func (session *fakeRemoteSession) CallTool(ctx context.Context, name string, arguments map[string]interface{}) (remoteCallResult, error) {
	session.calls = append(session.calls, name)
	if name == statusToolName {
		return session.status, nil
	}
	if session.callFn != nil {
		return session.callFn(ctx, name, arguments)
	}
	return remoteCallResult{Payload: json.RawMessage(`{"status":"ok"}`)}, nil
}

func (session *fakeRemoteSession) Close() error {
	session.closed++
	return nil
}

func newHealthyFakeSession() *fakeRemoteSession {
	definitions := compatibleDefinitions()
	available := make([]string, 0, len(definitions))
	for _, definition := range definitions {
		available = append(available, definition.Name)
	}
	status, err := json.Marshal(map[string]interface{}{
		"mode":             "fixture",
		"contract_version": expectedRemoteContractVersion,
		"available_tools":  available,
		"tool_contracts":   testStatusContracts(),
	})
	if err != nil {
		panic(err)
	}
	return &fakeRemoteSession{
		definitions: definitions,
		status:      remoteCallResult{Payload: status},
	}
}

func TestClientRejectsSessionWithoutCompatibleCoreTools(t *testing.T) {
	statusPayload, err := json.Marshal(map[string]interface{}{
		"mode":             "fixture",
		"contract_version": expectedRemoteContractVersion,
		"available_tools":  []string{statusToolName},
		"tool_contracts":   testStatusContracts(),
	})
	require.NoError(t, err)
	session := &fakeRemoteSession{
		definitions: []RemoteToolDefinition{{
			Name:         statusToolName,
			InputSchema:  json.RawMessage(`{"type":"object","properties":{},"additionalProperties":false}`),
			OutputSchema: json.RawMessage(`{"type":"object"}`),
		}},
		status: remoteCallResult{Payload: statusPayload},
	}
	client, _ := newTestClient(t, time.Second, session)
	err = client.Connect(context.Background())
	require.Equal(t, ErrorProtocol, ErrorCode(err))
	require.False(t, client.Healthy())
	require.Equal(t, 1, session.closed)
	definitions, listErr := client.ListTools(context.Background())
	require.Equal(t, ErrorProtocol, ErrorCode(listErr))
	require.Empty(t, definitions)
}

func TestClientHealthStatusReflectsValidatedSessionAndClearsOnClose(t *testing.T) {
	session := newHealthyFakeSession()
	client, _ := newTestClient(t, time.Second, session)

	require.NoError(t, client.Connect(context.Background()))
	status := client.HealthStatus()
	require.True(t, status.Healthy)
	require.Equal(t, "fixture", status.Mode)
	require.Equal(t, expectedRemoteContractVersion, status.ContractVersion)
	require.Equal(t, 3, status.AvailableTools)

	require.NoError(t, client.Close())
	require.Equal(t, ExternalMCPHealthStatus{}, client.HealthStatus())
}

func compatibleDefinitions() []RemoteToolDefinition {
	return []RemoteToolDefinition{
		{Name: statusToolName, InputSchema: json.RawMessage(`{"type":"object","properties":{},"additionalProperties":false}`), OutputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "compare_competitions", InputSchema: json.RawMessage(`{"type":"object","properties":{"student_profile":{},"competition_names":{},"competitions":{}},"required":["student_profile"],"additionalProperties":false}`), OutputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "analyze_academic_snapshot", InputSchema: json.RawMessage(`{"type":"object","properties":{"snapshot":{},"snapshot_path":{}},"additionalProperties":false}`), OutputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "plan_student_week", InputSchema: json.RawMessage(`{"type":"object","properties":{"schedule":{},"schedule_path":{},"goals":{},"constraints":{}},"additionalProperties":false}`), OutputSchema: json.RawMessage(`{"type":"object"}`)},
	}
}

func testStatusContracts() map[string]remoteContractStatus {
	result := make(map[string]remoteContractStatus, len(expectedRemoteToolContracts))
	for name, digest := range expectedRemoteToolContracts {
		result[name] = remoteContractStatus{SchemaSHA256: digest}
	}
	return result
}

func newTestClient(t *testing.T, timeout time.Duration, sessions ...remoteSession) (*Client, *int) {
	t.Helper()
	client, err := New(Config{
		Enabled:        true,
		Transport:      TransportLocalStdio,
		Command:        filepath.Join(os.TempDir(), "hy3-campus-decision-mcp"),
		ToolTimeout:    timeout,
		MaxCallsPerRun: 1,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	require.NoError(t, err)
	dialCount := 0
	client.dial = func(context.Context, Config) (remoteSession, error) {
		if dialCount >= len(sessions) {
			return nil, errors.New("没有可用的测试 MCP Session")
		}
		session := sessions[dialCount]
		dialCount++
		return session, nil
	}
	return client, &dialCount
}

func TestClientRejectsInvalidStatusResponse(t *testing.T) {
	tests := []struct {
		name   string
		status remoteCallResult
	}{
		{
			name:   "非 JSON 响应",
			status: remoteCallResult{Payload: json.RawMessage(`not-json`)},
		},
		{
			name: "未知运行模式",
			status: remoteCallResult{Payload: json.RawMessage(`{
				"mode":"unexpected","available_tools":["hy3_campus_status"]
			}`)},
		},
		{
			name: "未声明状态工具",
			status: remoteCallResult{Payload: json.RawMessage(`{
				"mode":"fixture","available_tools":["compare_competitions"]
			}`)},
		},
		{
			name:   "状态工具 IsError",
			status: remoteCallResult{Payload: json.RawMessage(`{"status":"error"}`), IsError: true},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			session := newHealthyFakeSession()
			session.status = test.status
			client, _ := newTestClient(t, time.Second, session)

			err := client.Connect(context.Background())
			require.Equal(t, ErrorProtocol, ErrorCode(err))
			require.False(t, client.Healthy())
			require.Equal(t, 1, session.closed)
		})
	}
}

func TestClientOnlyExposesSchemaAndStatusValidatedTools(t *testing.T) {
	session := newHealthyFakeSession()
	// 远端 Schema 变化时，不允许将同名但不兼容的工具注册给模型。
	session.definitions[2].InputSchema = json.RawMessage(`{"type":"object","properties":{"snapshot":{},"snapshot_path":{}},"additionalProperties":true}`)
	status, err := json.Marshal(map[string]interface{}{
		"mode":             "fixture",
		"contract_version": expectedRemoteContractVersion,
		"available_tools": []string{
			statusToolName,
			"compare_competitions",
			"analyze_academic_snapshot",
		},
		"tool_contracts": testStatusContracts(),
	})
	require.NoError(t, err)
	session.status = remoteCallResult{Payload: status}

	client, _ := newTestClient(t, time.Second, session)
	require.NoError(t, client.Connect(context.Background()))

	definitions, err := client.ListTools(context.Background())
	require.NoError(t, err)
	require.Equal(t, []string{"compare_competitions"}, remoteToolNames(definitions))

	_, err = client.CallTool(context.Background(), "analyze_academic_snapshot", map[string]interface{}{"snapshot": map[string]interface{}{}})
	require.Equal(t, ErrorToolMissing, ErrorCode(err))
	require.Equal(t, []string{statusToolName}, session.calls)
}

func TestClientRejectsUnsafeRemoteResults(t *testing.T) {
	tests := []struct {
		name   string
		result remoteCallResult
	}{
		{
			name:   "无效 JSON",
			result: remoteCallResult{Payload: json.RawMessage(`not-json`)},
		},
		{
			name:   "JSON 数组不是对象",
			result: remoteCallResult{Payload: json.RawMessage(`[]`)},
		},
		{
			name:   "结果超出限制",
			result: remoteCallResult{Payload: json.RawMessage(`{"data":"` + strings.Repeat("x", MaxResultBytes) + `"}`)},
		},
		{
			name:   "MCP 工具 IsError",
			result: remoteCallResult{Payload: json.RawMessage(`{"error":"remote"}`), IsError: true},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			session := newHealthyFakeSession()
			session.callFn = func(context.Context, string, map[string]interface{}) (remoteCallResult, error) {
				return test.result, nil
			}
			client, _ := newTestClient(t, time.Second, session)

			_, err := client.CallTool(context.Background(), "compare_competitions", map[string]interface{}{"competitions": []interface{}{}})
			require.Equal(t, ErrorInvalidResult, ErrorCode(err))
		})
	}
}

func TestClientClassifiesTimeoutAndReconnects(t *testing.T) {
	first := newHealthyFakeSession()
	first.callFn = func(ctx context.Context, _ string, _ map[string]interface{}) (remoteCallResult, error) {
		<-ctx.Done()
		return remoteCallResult{}, ctx.Err()
	}
	second := newHealthyFakeSession()
	client, dialCount := newTestClient(t, 15*time.Millisecond, first, second)

	_, err := client.CallTool(context.Background(), "compare_competitions", map[string]interface{}{"competitions": []interface{}{}})
	require.Equal(t, ErrorTimeout, ErrorCode(err))
	require.False(t, client.Healthy())
	require.Equal(t, 1, first.closed)

	payload, err := client.CallTool(context.Background(), "compare_competitions", map[string]interface{}{"competitions": []interface{}{}})
	require.NoError(t, err)
	require.JSONEq(t, `{"status":"ok"}`, string(payload))
	require.Equal(t, 2, *dialCount)
}

func TestClientReconnectsAfterConnectionLoss(t *testing.T) {
	first := newHealthyFakeSession()
	first.callFn = func(context.Context, string, map[string]interface{}) (remoteCallResult, error) {
		return remoteCallResult{}, io.EOF
	}
	second := newHealthyFakeSession()
	client, dialCount := newTestClient(t, time.Second, first, second)

	_, err := client.CallTool(context.Background(), "compare_competitions", map[string]interface{}{"competitions": []interface{}{}})
	require.Equal(t, ErrorUnavailable, ErrorCode(err))
	require.False(t, client.Healthy())
	require.Equal(t, 1, first.closed)

	_, err = client.CallTool(context.Background(), "compare_competitions", map[string]interface{}{"competitions": []interface{}{}})
	require.NoError(t, err)
	require.Equal(t, 2, *dialCount)
}

func TestClientMissingLocalWrapperFailsClosed(t *testing.T) {
	client, err := New(Config{
		Enabled:        true,
		Transport:      TransportLocalStdio,
		Command:        filepath.Join(t.TempDir(), "missing-mcp-wrapper"),
		ToolTimeout:    time.Second,
		MaxCallsPerRun: 1,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	require.NoError(t, err)

	err = client.Connect(context.Background())
	require.Equal(t, ErrorUnavailable, ErrorCode(err))
	require.False(t, client.Healthy())
	require.Equal(t, ExternalMCPHealthStatus{}, client.HealthStatus())
}

func TestSSHCommandBracketsIPv6AndDoesNotPassRemoteCommand(t *testing.T) {
	config := Config{
		Enabled:           true,
		Transport:         TransportSSHStdio,
		ToolTimeout:       time.Second,
		MaxCallsPerRun:    1,
		SSHHost:           "2001:db8::8",
		SSHPort:           2222,
		SSHUser:           "mcp-runner",
		SSHKeyPath:        filepath.Join(os.TempDir(), "mcp_ed25519"),
		SSHKnownHostsPath: filepath.Join(os.TempDir(), "mcp_known_hosts"),
	}
	require.NoError(t, config.Validate())

	command := sshCommand(config)
	require.Equal(t, "ssh", command.Args[0])
	require.Equal(t, "mcp-runner@[2001:db8::8]", command.Args[len(command.Args)-1])
	require.Equal(t, []string{
		"ssh", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
		"-o", "UserKnownHostsFile=" + config.SSHKnownHostsPath, "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
		"-o", "PermitLocalCommand=no", "-o", "RequestTTY=no", "-i", config.SSHKeyPath, "-p", "2222", "mcp-runner@[2001:db8::8]",
	}, command.Args)
}

func TestRealStdioContractIntegration(t *testing.T) {
	command := os.Getenv("HY3_MCP_COMMAND")
	if command == "" {
		t.Skip("设置 HY3_MCP_COMMAND 后运行真实 Python MCP stdio 契约测试")
	}
	previousContracts := expectedRemoteToolContracts
	expectedRemoteToolContracts = cloneContractDigests(productionExpectedRemoteToolContracts)
	t.Cleanup(func() { expectedRemoteToolContracts = previousContracts })
	repositoryRoot := filepath.Clean(filepath.Join("..", "..", "..", "..", "..", "xynewui_mcp"))
	t.Setenv("HY3_MODE", "fixture")
	t.Setenv("HY3_CAMPUS_ROOT", filepath.Join(repositoryRoot, "examples"))
	t.Setenv("HY3_FIXTURE_ROOT", filepath.Join(repositoryRoot, "tests", "fixtures", "hy3"))

	client, err := New(Config{
		Enabled:        true,
		Transport:      TransportLocalStdio,
		Command:        command,
		ToolTimeout:    10 * time.Second,
		MaxCallsPerRun: 1,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, client.Close()) })

	require.NoError(t, client.Connect(context.Background()))
	definitions, err := client.ListTools(context.Background())
	require.NoError(t, err)
	require.Equal(t, []string{
		"analyze_academic_snapshot", "compare_competitions", "compare_selected_competitions",
		"explain_competition_candidates", "plan_student_week",
	}, remoteToolNames(definitions))
	result, err := client.CallTool(context.Background(), "analyze_academic_snapshot", map[string]interface{}{
		"snapshot_path": "academic/safe_snapshot.json",
	})
	require.NoError(t, err)
	var envelope map[string]interface{}
	require.NoError(t, json.Unmarshal(result, &envelope))
	require.Equal(t, "ok", envelope["status"])
}

func remoteToolNames(definitions []RemoteToolDefinition) []string {
	result := make([]string, 0, len(definitions))
	for _, definition := range definitions {
		result = append(result, definition.Name)
	}
	return result
}
