package ai

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type scriptedToolProvider struct {
	mu       sync.Mutex
	rounds   [][]ProviderEvent
	requests []ProviderRequest
}

func (provider *scriptedToolProvider) Name() string { return "scripted" }
func (provider *scriptedToolProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{Streaming: true, ToolCalls: true, JSONSchema: true, UsageInStream: true}
}
func (provider *scriptedToolProvider) Start(_ context.Context, request ProviderRequest) (ProviderStream, error) {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	provider.requests = append(provider.requests, request)
	index := len(provider.requests) - 1
	if index >= len(provider.rounds) {
		return nil, &ProviderError{Class: ProviderErrorInvalid}
	}
	return &sliceProviderStream{events: provider.rounds[index]}, nil
}

func (provider *scriptedToolProvider) Requests() []ProviderRequest {
	provider.mu.Lock()
	defer provider.mu.Unlock()
	return append([]ProviderRequest(nil), provider.requests...)
}

type overviewTool struct {
	execute func(context.Context, uint, json.RawMessage) (interface{}, error)
}

func (overviewTool) Name() string    { return "academic.get_overview" }
func (overviewTool) Version() string { return "test" }
func (overviewTool) Definition() ToolDefinition {
	return ToolDefinition{
		Name:        "academic.get_overview",
		Description: "读取测试学业摘要。",
		Parameters: map[string]interface{}{
			"type": "object", "properties": map[string]interface{}{
				"topic": map[string]interface{}{"type": "string"},
			}, "required": []string{"topic"}, "additionalProperties": false,
		},
	}
}
func (tool overviewTool) Execute(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	return tool.execute(ctx, userID, arguments)
}

func newToolRuntime(t *testing.T, db *gorm.DB, provider AIProvider, tool PureReadTool) *Runtime {
	t.Helper()
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	runtime, err := NewRuntime(db, provider, fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 1, DocumentID: 1, Content: "已核验证据", Title: "测试资料",
	}}}}, NewEventBroker(), RuntimeConfig{
		ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
		MaxMessageChars: 100, HourlyMessageLimit: 10,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "tool-loop-test",
	}, registry)
	require.NoError(t, err)
	return runtime
}

func TestRuntimeToolLoopExecutesFragmentedArgumentsAndReturnsToProvider(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "call_1", ToolName: "academic.get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "call_1", ToolName: "academic.get_overview", ArgumentsDelta: `{"topic":`},
			{Type: ProviderEventToolArgumentsDelta, CallID: "call_1", ToolName: "academic.get_overview", ArgumentsDelta: `"grades"}`},
			{Type: ProviderEventUsage, InputTokens: 11, OutputTokens: 4},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已根据你的成绩摘要完成分析。"},
			{Type: ProviderEventUsage, InputTokens: 17, OutputTokens: 8},
			{Type: ProviderEventCompleted},
		},
	}}
	tool := overviewTool{execute: func(_ context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
		require.Equal(t, uint(7), userID)
		require.JSONEq(t, `{"topic":"grades"}`, string(arguments))
		return map[string]interface{}{"failed_course_count": 0}, nil
	}}
	runtime := newToolRuntime(t, db, provider, tool)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请分析我的成绩"})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, "completed")
	require.Equal(t, "已根据你的成绩摘要完成分析。", completed.AnswerCheckpoint)

	requests := provider.Requests()
	require.Len(t, requests, 2)
	require.Len(t, requests[0].Tools, 1)
	require.Equal(t, "academic.get_overview", requests[0].Tools[0].Name)
	require.Len(t, requests[1].Messages, 4)
	require.Equal(t, "assistant", requests[1].Messages[2].Role)
	require.Equal(t, "call_1", requests[1].Messages[2].ToolCalls[0].ID)
	require.Equal(t, `{"topic":"grades"}`, requests[1].Messages[2].ToolCalls[0].Function.Arguments)
	require.Equal(t, "tool", requests[1].Messages[3].Role)
	require.Equal(t, "call_1", requests[1].Messages[3].ToolCallID)
	require.JSONEq(t, `{"failed_course_count":0}`, requests[1].Messages[3].Content)

	var callCount int64
	require.NoError(t, db.Table("ai_tool_calls").Where("run_id = ? AND status = ?", run.ID, "completed").Count(&callCount).Error)
	require.Equal(t, int64(1), callCount)
	events, err := runtime.EventsAfter(context.Background(), 7, run.ID, 0)
	require.NoError(t, err)
	eventTypes := make(map[string]bool, len(events))
	for _, event := range events {
		eventTypes[event.Type] = true
	}
	require.True(t, eventTypes["tool.requested"])
	require.True(t, eventTypes["tool.executing"])
	require.True(t, eventTypes["tool.completed"])
}

func TestToolRegistryRejectsNestedModelUserID(t *testing.T) {
	db := newRuntimeTestDB(t)
	executed := false
	registry, err := NewToolRegistry(db, overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		executed = true
		return map[string]bool{"ok": true}, nil
	}})
	require.NoError(t, err)
	_, _, err = registry.Execute(context.Background(), "call_identity", uuid.NewString(), 7, "academic.get_overview", json.RawMessage(`{"nested":{"user_id":9}}`))
	require.EqualError(t, err, "invalid_tool_call")
	require.False(t, executed)
}

func TestRuntimeResumesWaitingDeviceJobOnlyOnce(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "device_call", ToolName: "academic.get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "device_call", ToolName: "academic.get_overview", ArgumentsDelta: `{"topic":"grades"}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已结合手机中的成绩摘要完成分析。"},
			{Type: ProviderEventCompleted},
		},
	}}
	tool := overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		return ToolWait{
			State: models.AIRunStateWaitingDevice, EventType: "device.waiting", ResumeKey: "device-job-1",
			Payload: map[string]interface{}{"datasets": []string{"grades"}},
		}, nil
	}}
	runtime := newToolRuntime(t, db, provider, tool)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "分析成绩"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateWaitingDevice)
	require.Len(t, provider.Requests(), 1)

	require.NoError(t, db.Create(&models.DeviceToolJob{
		ID: "device-job-1", UserID: 7, RunID: run.ID, ToolCallID: "device_call",
		InstallationID: "test-installation", ToolName: "device.academic.get_cached_overview",
		ArgumentsJSON: datatypes.JSON([]byte(`{}`)), RequiredDataTypes: datatypes.JSON([]byte(`["academic"]`)),
		Status: models.DeviceToolJobCompleted, StateVersion: 3, ExpiresAt: time.Now().Add(time.Minute),
		ResultJSON: datatypes.JSON([]byte(`{"failed_course_count":1,"is_stale":false}`)),
	}).Error)

	require.NoError(t, runtime.ResumeDeviceJob(context.Background(), "device-job-1"))
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "已结合手机中的成绩摘要完成分析。", completed.AnswerCheckpoint)

	var call models.AIToolCall
	require.NoError(t, db.First(&call, "call_id = ?", "device_call").Error)
	require.Equal(t, "completed", call.Status)
	require.JSONEq(t, `{"failed_course_count":1,"is_stale":false}`, string(call.ResultJSON))
	require.Len(t, provider.Requests(), 2)

	// 设备端网络重试可能重复上报完成，恢复入口必须保持幂等且不得再次调用 Provider。
	require.NoError(t, runtime.ResumeDeviceJob(context.Background(), "device-job-1"))
	time.Sleep(100 * time.Millisecond)
	require.Len(t, provider.Requests(), 2)
}

func TestRuntimeResumesWaitingUserConsent(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "consent_call", ToolName: "academic.get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "consent_call", ToolName: "academic.get_overview", ArgumentsDelta: `{"topic":"grades"}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已在授权完成后重新读取最新数据。"},
			{Type: ProviderEventCompleted},
		},
	}}
	tool := overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		return ToolWait{
			State: models.AIRunStateWaitingUserConsent, EventType: "consent.required",
			Payload: map[string]interface{}{"datasets": []string{"grades"}},
		}, nil
	}}
	runtime := newToolRuntime(t, db, provider, tool)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "刷新后分析成绩"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateWaitingUserConsent)
	require.NoError(t, runtime.ResumeUserConsent(context.Background(), 7))
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Len(t, provider.Requests(), 2)

	secondRequest := provider.Requests()[1]
	require.Len(t, secondRequest.Messages, 4)
	require.Equal(t, "tool", secondRequest.Messages[3].Role)
	require.JSONEq(t, `{"status":"completed","consent_granted":true,"instruction":"请重新读取已授权数据"}`, secondRequest.Messages[3].Content)
}

func TestExtractPersonalDataEvidenceOnlyEmitsAllowedMetadata(t *testing.T) {
	fetchedAt := time.Date(2026, time.July, 25, 9, 20, 0, 0, time.UTC)
	result := json.RawMessage(`{
		"data":{"grades":[{"course_name":"高等数学","score":92}]},
		"source":"public_database",
		"evidence":[
			{"source":"server_snapshot","dataset":"grades","title":"高等数学：92","fetched_at":"2026-07-25T09:20:00Z","is_stale":false},
			{"source":"server_snapshot","dataset":"grades","title":"线性代数：88","fetched_at":"2026-07-25T09:20:00Z","is_stale":false},
			{"source":"public_database","dataset":"grades","title":"不应进入个人数据事件","fetched_at":"2026-07-25T09:20:00Z","is_stale":false}
		]
	}`)

	evidence := extractPersonalDataEvidence(result)
	require.Len(t, evidence, 1)
	require.Equal(t, "server_snapshot", evidence[0].Source)
	require.Equal(t, "grades", evidence[0].Dataset)
	require.Equal(t, fetchedAt, *evidence[0].FetchedAt)
	require.Empty(t, evidence[0].Title)

	payload, err := json.Marshal(evidence)
	require.NoError(t, err)
	require.NotContains(t, string(payload), "高等数学")
	require.NotContains(t, string(payload), "92")
	require.NotContains(t, string(payload), "public_database")
}
