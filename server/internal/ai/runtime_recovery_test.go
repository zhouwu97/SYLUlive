package ai

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

func TestRuntimeGreetingRespondsWithoutProviderOrRetrieval(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{}
	runtime := newToolRuntime(t, db, provider, overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		t.Error("纯问候不应读取个人数据")
		return nil, nil
	}})
	retriever := &countingRetriever{}
	runtime.retriever = retriever
	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "nihao"})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Contains(t, completed.AnswerCheckpoint, "你好")
	require.Empty(t, provider.Requests())
	require.Zero(t, retriever.Calls())
	events, err := runtime.EventsAfter(context.Background(), 7, run.ID, 0)
	require.NoError(t, err)
	foundAnswer, foundCompleted := false, false
	for _, event := range events {
		foundAnswer = foundAnswer || event.Type == "answer.completed"
		foundCompleted = foundCompleted || event.Type == "run.completed"
	}
	require.True(t, foundAnswer)
	require.True(t, foundCompleted)
}

func TestCampusGreetingDoesNotSwallowTasks(t *testing.T) {
	for _, message := range []string{"nihao", "你好！", " Hello "} {
		require.NotEmpty(t, campusGreetingReply(message))
	}
	for _, message := range []string{"你好，帮我查成绩", "nihao 查课表", "你好是什么意思", "what can you do", "hi there, help me with homework"} {
		require.Empty(t, campusGreetingReply(message), message)
	}
}

type timeoutAfterAcademicTool struct{ scriptedToolProvider }

func (p *timeoutAfterAcademicTool) Start(ctx context.Context, request ProviderRequest) (ProviderStream, error) {
	if len(p.Requests()) > 0 {
		return nil, &ProviderError{Class: ProviderErrorTimeout}
	}
	return p.scriptedToolProvider.Start(ctx, request)
}

func TestRuntimeKeepsVerifiedAcademicDataAfterProviderTimeout(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &timeoutAfterAcademicTool{scriptedToolProvider{rounds: [][]ProviderEvent{{
		{Type: ProviderEventToolCallStarted, CallID: "risk", ToolName: modelToolAcademicRisk},
		{Type: ProviderEventToolArgumentsDelta, CallID: "risk", ToolName: modelToolAcademicRisk, ArgumentsDelta: `{}`},
		{Type: ProviderEventCompleted},
	}}}}
	tool := namedOverviewTool{name: modelToolAcademicRisk, overviewTool: overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		return map[string]interface{}{"status": "available", "data": map[string]interface{}{
			"grades": map[string]interface{}{"course_count": 64}, "risk_level": "needs_attention", "risks": []string{"存在未通过课程"},
		}}, nil
	}}}
	runtime := newToolRuntime(t, db, provider, tool)
	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "分析我的学业情况"})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Contains(t, completed.AnswerCheckpoint, "64 门课程")
	require.Contains(t, completed.AnswerCheckpoint, "存在未通过课程")
	require.Empty(t, completed.ErrorCode)
	require.False(t, runtime.completeVerifiedAcademicFallback(run.ID, ProviderErrorCancelled, ProviderEvent{}, 0))
}
