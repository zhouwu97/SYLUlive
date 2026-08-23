package ai

import (
	"context"
	"encoding/json"
	"strings"
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

type countingRetriever struct {
	mu    sync.Mutex
	calls int
}

func (retriever *countingRetriever) Retrieve(context.Context, string) (RetrievalResult, error) {
	retriever.mu.Lock()
	defer retriever.mu.Unlock()
	retriever.calls++
	return RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 1, DocumentID: 1, Content: "弱相关政策资料", Title: "测试政策",
	}}}, nil
}

func (retriever *countingRetriever) Calls() int {
	retriever.mu.Lock()
	defer retriever.mu.Unlock()
	return retriever.calls
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

type namedOverviewTool struct {
	overviewTool
	name string
}

func (tool namedOverviewTool) Name() string { return tool.name }
func (tool namedOverviewTool) Definition() ToolDefinition {
	definition := tool.overviewTool.Definition()
	definition.Name = tool.name
	return definition
}

func newToolRuntime(t *testing.T, db *gorm.DB, provider AIProvider, tool PureReadTool) *Runtime {
	return newToolRuntimeWithMaxToolSteps(t, db, provider, tool, 4)
}

func newToolRuntimeWithMaxToolSteps(t *testing.T, db *gorm.DB, provider AIProvider, tool PureReadTool, maxToolSteps int) *Runtime {
	t.Helper()
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	runtime, err := NewRuntime(db, provider, fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 1, DocumentID: 1, Content: "已核验证据", Title: "测试资料",
	}}}}, NewEventBroker(), RuntimeConfig{
		ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
		MaxToolSteps:    maxToolSteps,
		MaxMessageChars: 20, HourlyMessageLimit: 10,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "tool-loop-test",
	}, WithToolRegistry(registry))
	require.NoError(t, err)
	return runtime
}

func TestRuntimeToolLoopSynthesizesFinalAnswerAfterConfiguredMaxToolSteps(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "call_1", ToolName: "academic.get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "call_1", ToolName: "academic.get_overview", ArgumentsDelta: `{"topic":"grades"}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已根据工具结果完成回答。"},
			{Type: ProviderEventCompleted},
		},
	}}
	executions := 0
	runtime := newToolRuntimeWithMaxToolSteps(t, db, provider, overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		executions++
		return map[string]bool{"ok": true}, nil
	}}, 1)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请分析成绩"})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "已根据工具结果完成回答。", completed.AnswerCheckpoint)
	require.Equal(t, 1, executions)
	requests := provider.Requests()
	require.Len(t, requests, 2)
	require.Len(t, requests[0].Tools, 1)
	require.Empty(t, requests[1].Tools, "达到工具轮数上限后必须禁用工具，只允许模型组织最终回答")
}

func TestRuntimeToolLoopValidatesCitationsAndEmitsSources(t *testing.T) {
	db := newRuntimeTestDB(t)
	seedPublishedKnowledgeSource(t, db, 1, 1)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "citation_call", ToolName: "academic.get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "citation_call", ToolName: "academic.get_overview", ArgumentsDelta: `{"topic":"grades"}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已根据工具结果完成回答。[chunk:1]"},
			{Type: ProviderEventCompleted},
		},
	}}
	runtime := newToolRuntime(t, db, provider, overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		return map[string]bool{"ok": true}, nil
	}})

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "请分析我的成绩",
	})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "已根据工具结果完成回答。[1]", completed.AnswerCheckpoint)
	require.NotContains(t, completed.AnswerCheckpoint, "chunk:")

	var sourceEvent models.AIEvent
	require.NoError(t, db.Where("run_id = ? AND type = ?", run.ID, "sources.ready").First(&sourceEvent).Error)
	var payload struct {
		Sources []SourceCard `json:"sources"`
	}
	require.NoError(t, json.Unmarshal(sourceEvent.Payload, &payload))
	require.Len(t, payload.Sources, 1)
	require.Equal(t, uint(1), payload.Sources[0].DocumentID)
	require.Equal(t, []int{1}, payload.Sources[0].CitationNumbers)
}

func TestRuntimeDoesNotSynthesizeAcademicAnalysisWhenHy3ContextUnavailable(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "hy3_unavailable", ToolName: "hy3_decision_analyze_academic"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "hy3_unavailable", ToolName: "hy3_decision_analyze_academic", ArgumentsDelta: `{}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "这是没有个人数据依据的通用分析。"},
			{Type: ProviderEventCompleted},
		},
	}}
	tool := namedOverviewTool{
		name: "hy3_decision.analyze_academic",
		overviewTool: overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
			return map[string]interface{}{
				"status": "unavailable", "error_code": "personal_context_unavailable",
				"warnings": []string{"学业快照不可用"},
			}, nil
		}},
	}
	runtime := newToolRuntime(t, db, provider, tool)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "分析我的学业情况",
	})
	require.NoError(t, err)
	failed := waitRunState(t, db, run.ID, models.AIRunStateFailed)
	require.Equal(t, "personal_context_unavailable", failed.ErrorCode)
	require.Empty(t, failed.AnswerCheckpoint)
	require.Len(t, provider.Requests(), 1, "Hy3 不可用后不得让模型伪造个人分析")
}

func TestRuntimeRequiresPersonalDecisionToolBeforeFinalAnswer(t *testing.T) {
	tests := []struct {
		name        string
		message     string
		toolName    string
		modelName   string
		unsafeReply string
		retrievals  int
	}{
		{
			name:        "学业分析",
			message:     "分析我的学业情况，找出主要风险并给出改进建议",
			toolName:    "hy3_decision.analyze_academic",
			modelName:   "hy3_decision_analyze_academic",
			unsafeReply: "你的主要学业风险通常集中在成绩门槛和课程不及格。",
			retrievals:  1,
		},
		{
			name:        "本周学习计划",
			message:     "结合我的课表和目标，帮我制定本周学习计划",
			toolName:    "hy3_decision.plan_student_week",
			modelName:   "hy3_decision_plan_student_week",
			unsafeReply: "本周学习计划应按目标优先、课前预习来排。",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			db := newRuntimeTestDB(t)
			provider := &scriptedToolProvider{rounds: [][]ProviderEvent{{
				{Type: ProviderEventTextDelta, Text: test.unsafeReply},
				{Type: ProviderEventCompleted},
			}}}
			retriever := &countingRetriever{}
			tool := namedOverviewTool{name: test.toolName, overviewTool: overviewTool{
				execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
					t.Fatal("模型未发起工具调用时不应执行工具")
					return nil, nil
				},
			}}
			registry, err := NewToolRegistry(db, tool)
			require.NoError(t, err)
			runtime, err := NewRuntime(db, provider, retriever, NewEventBroker(), RuntimeConfig{
				ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
				MaxToolSteps: 3, MaxMessageChars: 100, HourlyMessageLimit: 10,
				DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
				InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
				AuditHashSecret: "required-tool-test",
			}, WithToolRegistry(registry))
			require.NoError(t, err)

			run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
				ClientRequestID: uuid.NewString(), Message: test.message,
			})
			require.NoError(t, err)
			failed := waitRunState(t, db, run.ID, models.AIRunStateFailed)
			require.Equal(t, "required_tool_not_used", failed.ErrorCode)
			require.Empty(t, failed.AnswerCheckpoint)
			require.Equal(t, test.retrievals, retriever.Calls())

			requests := provider.Requests()
			require.Len(t, requests, 1)
			require.Equal(t, test.modelName, requests[0].RequiredTool)
			require.Len(t, requests[0].Tools, 1)
			require.Equal(t, test.modelName, requests[0].Tools[0].Name)

			var assistantMessages int64
			require.NoError(t, db.Model(&models.AIConversationMessage{}).
				Where("run_id = ? AND role = ?", run.ID, "assistant").Count(&assistantMessages).Error)
			require.Zero(t, assistantMessages)
		})
	}
}

func TestRuntimeCompletesAfterRequiredPersonalDecisionTool(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "required_academic", ToolName: "hy3_decision_analyze_academic"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "required_academic", ToolName: "hy3_decision_analyze_academic", ArgumentsDelta: `{}`},
			{Type: ProviderEventCompleted, FinishReason: "tool_calls"},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已基于学业工具结果完成分析。"},
			{Type: ProviderEventCompleted, FinishReason: "stop"},
		},
	}}
	retriever := &countingRetriever{}
	tool := namedOverviewTool{name: "hy3_decision.analyze_academic", overviewTool: overviewTool{
		execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
			return map[string]interface{}{"status": "ok", "source": "server_snapshot"}, nil
		},
	}}
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	runtime, err := NewRuntime(db, provider, retriever, NewEventBroker(), RuntimeConfig{
		ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
		MaxToolSteps: 3, MaxMessageChars: 100, HourlyMessageLimit: 10,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "required-tool-success-test",
	}, WithToolRegistry(registry))
	require.NoError(t, err)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "分析我的学业情况，找出主要风险并给出改进建议",
	})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "已基于学业工具结果完成分析。", completed.AnswerCheckpoint)
	require.Equal(t, 1, retriever.Calls())
	requests := provider.Requests()
	require.Len(t, requests, 2)
	require.Equal(t, "hy3_decision_analyze_academic", requests[0].RequiredTool)
	require.Empty(t, requests[1].RequiredTool)

	var calls []models.AIToolCall
	require.NoError(t, db.Where("run_id = ?", run.ID).Find(&calls).Error)
	require.Len(t, calls, 1)
	require.Equal(t, "completed", calls[0].Status)
}

func TestAcademicAnalysisEmitsPersonalEvidenceAndPolicySources(t *testing.T) {
	db := newRuntimeTestDB(t)
	seedPublishedKnowledgeSource(t, db, 1, 1)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "academic_with_sources", ToolName: "hy3_decision_analyze_academic"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "academic_with_sources", ToolName: "hy3_decision_analyze_academic", ArgumentsDelta: `{}`},
			{Type: ProviderEventCompleted, FinishReason: "tool_calls"},
		},
		{
			{Type: ProviderEventTextDelta, Text: "信号与系统目前未通过，建议先复习薄弱章节。后续补考或重修应以学校规定为准。[chunk:1]"},
			{Type: ProviderEventCompleted, FinishReason: "stop"},
		},
	}}
	tool := namedOverviewTool{name: "hy3_decision.analyze_academic", overviewTool: overviewTool{
		execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
			return map[string]interface{}{
				"status": "ok",
				"analysis": map[string]interface{}{
					"risk_summary": "failed_required_credits 为3，建议后续补考或重修",
				},
				"deterministic_findings": map[string]interface{}{
					"failed_course_count": 1, "failed_required_credits": 3,
					"earned_credits": 25.5, "credit_gap": 0, "erke_gap": 0,
					"unknown_grade_course_count": 0, "missing_credit_course_count": 0,
					"data_completeness_percent": 100, "failed_courses": []string{"信号与系统"},
				},
				"analysis_input": map[string]interface{}{
					"courses": []map[string]interface{}{{
						"course_name": "信号与系统", "grade": 58.0, "credits": 3.0,
						"is_required": true, "passed": false,
					}},
					"earned_credits": 25.5, "required_credits": 25.5,
					"erke_earned": 0.0, "erke_required": 0.0,
				},
				"source": "hy3_mcp", "warnings": []string{},
			}, nil
		},
	}}
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	retriever := fixedRetriever{result: RetrievalResult{
		Plan: BuildPolicyQueryPlan("挂科了怎么办"),
		Chunks: []RetrievedChunk{{
			ChunkID: 1, DocumentID: 1, DocumentType: DocTypeStatusPolicy,
			Title: "学生手册", Content: "课程首次考核不合格后，按学校规定参加后续考核。",
		}},
	}}
	runtime, err := NewRuntime(db, provider, retriever, NewEventBroker(), RuntimeConfig{
		ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
		MaxToolSteps: 3, MaxMessageChars: 100, HourlyMessageLimit: 10,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "academic-evidence-test",
	}, WithToolRegistry(registry))
	require.NoError(t, err)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "分析我的学业情况，找出主要风险并给出改进建议",
	})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Contains(t, completed.AnswerCheckpoint, "[1]")

	requests := provider.Requests()
	require.Len(t, requests, 2)
	require.Contains(t, requests[1].Messages[len(requests[1].Messages)-1].Content, "未通过必修课程涉及学分")
	require.NotContains(t, requests[1].Messages[len(requests[1].Messages)-1].Content, "failed_required_credits")
	require.NotContains(t, requests[1].Messages[len(requests[1].Messages)-1].Content, "risk_summary")

	var personalEvent models.AIEvent
	require.NoError(t, db.Where("run_id = ? AND type = ?", run.ID, "personal_data.evidence").First(&personalEvent).Error)
	require.Contains(t, string(personalEvent.Payload), "信号与系统")
	var sourcesEvent models.AIEvent
	require.NoError(t, db.Where("run_id = ? AND type = ?", run.ID, "sources.ready").First(&sourcesEvent).Error)
	require.Contains(t, string(sourcesEvent.Payload), "学生手册")
}

func TestAcademicAnalysisDoesNotDeliverCampusProcedureWithoutPolicySource(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "academic_without_sources", ToolName: "hy3_decision_analyze_academic"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "academic_without_sources", ToolName: "hy3_decision_analyze_academic", ArgumentsDelta: `{}`},
			{Type: ProviderEventCompleted, FinishReason: "tool_calls"},
		},
		{
			{Type: ProviderEventTextDelta, Text: "请关注后续补考或重修安排。"},
			{Type: ProviderEventCompleted, FinishReason: "stop"},
		},
	}}
	tool := namedOverviewTool{name: "hy3_decision.analyze_academic", overviewTool: overviewTool{
		execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
			return map[string]interface{}{
				"status": "ok",
				"deterministic_findings": map[string]interface{}{
					"failed_course_count": 1, "failed_required_credits": 3,
					"earned_credits": 25.5, "credit_gap": 0, "erke_gap": 0,
					"unknown_grade_course_count": 0, "missing_credit_course_count": 0,
					"data_completeness_percent": 100, "failed_courses": []string{"信号与系统"},
				},
				"analysis_input": map[string]interface{}{}, "warnings": []string{},
			}, nil
		},
	}}
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	runtime, err := NewRuntime(db, provider, fixedRetriever{}, NewEventBroker(), RuntimeConfig{
		ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
		MaxToolSteps: 3, MaxMessageChars: 100, HourlyMessageLimit: 10,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "academic-no-policy-test",
	}, WithToolRegistry(registry))
	require.NoError(t, err)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "分析我的学业情况，找出主要风险并给出改进建议",
	})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, unverifiableCampusAnswer, completed.AnswerCheckpoint)
	require.NotContains(t, completed.AnswerCheckpoint, "补考或重修安排")
}

func TestRuntimeUsesVerifiedRAGWithoutPublicToolsForKnownPolicyIntent(t *testing.T) {
	db := newRuntimeTestDB(t)
	seedPublishedKnowledgeSource(t, db, 1, 1)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{{
		{Type: ProviderEventTextDelta, Text: "补考总成绩按课程比例合成。[chunk:1]"},
		{Type: ProviderEventCompleted},
	}}}
	tool := namedOverviewTool{
		overviewTool: overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
			t.Fatal("已命中政策 RAG 时不应执行公开搜索工具")
			return nil, nil
		}},
		name: "campus.search_policy",
	}
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	runtime, err := NewRuntime(db, provider, fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 1, DocumentID: 1, Title: "补考成绩现行口径",
		Content: "补考总成绩由原平时成绩与补考卷面成绩按课程规定比例合成。",
	}}}}, NewEventBroker(), RuntimeConfig{
		ProviderName: "scripted", Model: "scripted", RequestTimeout: 5 * time.Second,
		MaxToolSteps: 4, MaxMessageChars: 20, HourlyMessageLimit: 10,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "tool-loop-test",
	}, WithToolRegistry(registry))
	require.NoError(t, err)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "补考成绩怎么算"})
	require.NoError(t, err)
	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Contains(t, completed.AnswerCheckpoint, "[1]")
	require.Len(t, provider.Requests(), 1)
	require.Empty(t, provider.Requests()[0].Tools)
}

func TestRuntimeToolLoopExecutesFragmentedArgumentsAndReturnsToProvider(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "call_1", ToolName: "academic_get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "call_1", ToolName: "academic_get_overview", ArgumentsDelta: `{"topic":`},
			{Type: ProviderEventToolArgumentsDelta, CallID: "call_1", ToolName: "academic_get_overview", ArgumentsDelta: `"grades"}`},
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
	require.Equal(t, "academic_get_overview", requests[0].Tools[0].Name)
	require.Len(t, requests[1].Messages, 4)
	require.Equal(t, "assistant", requests[1].Messages[2].Role)
	require.Equal(t, "call_1", requests[1].Messages[2].ToolCalls[0].ID)
	require.Equal(t, "academic_get_overview", requests[1].Messages[2].ToolCalls[0].Function.Name)
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

func TestAcademicRiskFallbackRejectsFalseReassurance(t *testing.T) {
	fallback, riskSeen := academicRiskFallback("academic_get_risk_analysis", json.RawMessage(`{
		"status":"available",
		"data":{
			"risk_level":"incomplete",
			"risks":["发现 1 门未通过课程（大学物理B2）"],
			"actions":["核对未通过课程的补考或重修安排"],
			"to_confirm":["确认当前快照是否覆盖全部已修学期"]
		},
		"warnings":[]
	}`))
	require.True(t, riskSeen)
	require.Contains(t, fallback, "大学物理B2")
	require.True(t, academicAnswerNeedsGuard("总体风险不大，建议继续保持。", fallback, riskSeen))
	require.False(t, academicAnswerNeedsGuard("已确认大学物理B2未通过，建议核对补考安排。", fallback, riskSeen))
}

func TestAcademicRiskMissingDataCanStillProduceBoundedAnswer(t *testing.T) {
	fallback, riskSeen := academicRiskFallback("academic_get_risk_analysis", json.RawMessage(`{
		"status":"missing",
		"data":{
			"risk_level":"incomplete",
			"risks":[],
			"actions":[],
			"to_confirm":["刷新或授权读取成绩快照后再判断挂科风险"]
		},
		"warnings":["服务端没有可用快照"]
	}`))
	require.True(t, riskSeen)
	require.Contains(t, fallback, "刷新或授权读取成绩快照")
}

func TestToolRegistryMapsModelAliasesBackToCanonicalNames(t *testing.T) {
	db := newRuntimeTestDB(t)
	executed := false
	tool := namedOverviewTool{
		overviewTool: overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
			executed = true
			return map[string]bool{"ok": true}, nil
		}},
		name: "hy3_decision.analyze_academic",
	}
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	require.Equal(t, "hy3_decision_analyze_academic", registry.Definitions()[0].Name)

	runID := uuid.NewString()
	require.NoError(t, db.Create(&models.AIRun{
		ID: runID, UserID: 7, ConversationID: uuid.NewString(), ClientRequestID: uuid.NewString(),
		State: models.AIRunStateToolExecuting, Provider: "scripted", Model: "scripted",
		MessageHash: strings.Repeat("a", 64), MessageLength: 1, ExpiresAt: time.Now().Add(time.Minute),
	}).Error)
	_, _, err = registry.Execute(
		context.Background(), "hy3_alias_call", runID, 7,
		"hy3_decision_analyze_academic", json.RawMessage(`{"topic":"grades"}`),
	)
	require.NoError(t, err)
	require.True(t, executed)

	var call models.AIToolCall
	require.NoError(t, db.First(&call, "call_id = ?", "hy3_alias_call").Error)
	require.Equal(t, "hy3_decision.analyze_academic", call.ToolName)
}

func TestToolRegistryRejectsModelAliasCollisions(t *testing.T) {
	first := namedOverviewTool{overviewTool: overviewTool{}, name: "campus.search_policy"}
	second := namedOverviewTool{overviewTool: overviewTool{}, name: "campus_search_policy"}
	_, err := NewToolRegistry(newRuntimeTestDB(t), first, second)
	require.ErrorContains(t, err, "duplicate AI model tool")
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
	executions := 0
	tool := overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		executions++
		if executions == 1 {
			return ToolWait{
				State: models.AIRunStateWaitingDevice, EventType: "device.waiting", ResumeKey: "device-job-1",
				Payload: map[string]interface{}{"datasets": []string{"grades"}},
			}, nil
		}
		// 恢复必须重新执行外层工具；设备结果不能直接冒充该工具的结果。
		return map[string]interface{}{"source": "outer_tool", "analysis": "complete"}, nil
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
	require.JSONEq(t, `{"source":"outer_tool","analysis":"complete"}`, string(call.ResultJSON))
	require.Equal(t, 2, executions)
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
	executions := 0
	tool := overviewTool{execute: func(_ context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
		executions++
		require.JSONEq(t, `{"topic":"grades"}`, string(arguments))
		if executions == 1 {
			return ToolWait{
				State: models.AIRunStateWaitingUserConsent, EventType: "consent.required",
				ConsentScope: models.AIUserPermissionPersonalDataAccess,
				Payload:      map[string]interface{}{"scope": models.AIUserPermissionPersonalDataAccess, "datasets": []string{"grades"}},
			}, nil
		}
		return map[string]interface{}{"source": "server_snapshot", "failed_course_count": 0}, nil
	}}
	runtime := newToolRuntime(t, db, provider, tool)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "刷新后分析成绩"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateWaitingUserConsent)
	require.NoError(t, runtime.ResumeRunConsent(context.Background(), 7, run.ID, models.AIUserPermissionPersonalDataAccess, true))
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Len(t, provider.Requests(), 2)
	require.Equal(t, 2, executions)

	secondRequest := provider.Requests()[1]
	require.Len(t, secondRequest.Messages, 4)
	require.Equal(t, "tool", secondRequest.Messages[3].Role)
	require.JSONEq(t, `{"source":"server_snapshot","failed_course_count":0}`, secondRequest.Messages[3].Content)
}

func TestRuntimeRetriesSameToolAcrossSequentialConsentsBeforeCallingProvider(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "hy3_consent_call", ToolName: "hy3_decision_analyze_academic"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "hy3_consent_call", ToolName: "hy3_decision_analyze_academic", ArgumentsDelta: `{"question":"计算我的 GPA 和学分情况"}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "已根据 Hy3 的真实结果完成分析。"},
			{Type: ProviderEventCompleted},
		},
	}}
	scopes := []models.AIUserPermissionScope{
		models.AIUserPermissionPersonalDataAccess,
		models.AIUserPermissionAcademicCloudStorage,
		models.AIUserPermissionExternalModelAnalysis,
	}
	executions := 0
	remoteCalls := 0
	tool := namedOverviewTool{
		name: "hy3_decision.analyze_academic",
		overviewTool: overviewTool{execute: func(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
			require.Equal(t, uint(7), userID)
			require.JSONEq(t, `{"question":"计算我的 GPA 和学分情况"}`, string(arguments))
			require.LessOrEqual(t, executions, len(scopes))
			if executions < len(scopes) {
				scope := scopes[executions]
				executions++
				return ToolWait{
					State: models.AIRunStateWaitingUserConsent, EventType: "consent.required", ConsentScope: scope,
					Payload: map[string]interface{}{"scope": scope},
				}, nil
			}
			executions++
			remoteCalls++
			return map[string]interface{}{"source": "hy3_mcp", "gpa": 3.72, "credits": 96}, nil
		}},
	}
	runtime := newToolRuntime(t, db, provider, tool)

	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "计算我的 GPA 和学分情况",
	})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateWaitingUserConsent)
	require.Len(t, provider.Requests(), 1)

	for index, scope := range scopes {
		require.NoError(t, runtime.ResumeRunConsent(context.Background(), 7, run.ID, scope, true))
		if scope != models.AIUserPermissionExternalModelAnalysis {
			nextScope := scopes[index+1]
			require.Eventually(t, func() bool {
				var resume models.AIRunResumeJob
				if err := db.Where("run_id = ? AND status = ?", run.ID, "waiting").First(&resume).Error; err != nil {
					return false
				}
				pending, err := decodePendingToolCalls(json.RawMessage(resume.PendingToolCallsJSON))
				return err == nil && len(pending) == 1 && pending[0].ConsentScope == nextScope
			}, 3*time.Second, 10*time.Millisecond)
			require.Len(t, provider.Requests(), 1)
		}
	}

	completed := waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Equal(t, "已根据 Hy3 的真实结果完成分析。", completed.AnswerCheckpoint)
	require.Equal(t, 4, executions)
	require.Equal(t, 1, remoteCalls)
	require.Len(t, provider.Requests(), 2)

	secondRequest := provider.Requests()[1]
	require.Len(t, secondRequest.Messages, 4)
	require.Equal(t, "hy3_consent_call", secondRequest.Messages[3].ToolCallID)
	require.JSONEq(t, `{"source":"hy3_mcp","gpa":3.72,"credits":96}`, secondRequest.Messages[3].Content)

	var call models.AIToolCall
	require.NoError(t, db.First(&call, "call_id = ?", "hy3_consent_call").Error)
	require.Equal(t, "completed", call.Status)
	require.Equal(t, "hy3_decision.analyze_academic", call.ToolName)
	require.JSONEq(t, `{"source":"hy3_mcp","gpa":3.72,"credits":96}`, string(call.ResultJSON))
}

func TestResumeRunConsentRejectsOtherUserAndMismatchedScope(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{
		{
			{Type: ProviderEventToolCallStarted, CallID: "consent_guard_call", ToolName: "academic.get_overview"},
			{Type: ProviderEventToolArgumentsDelta, CallID: "consent_guard_call", ToolName: "academic.get_overview", ArgumentsDelta: `{"topic":"grades"}`},
			{Type: ProviderEventCompleted},
		},
		{
			{Type: ProviderEventTextDelta, Text: "用户拒绝后未读取个人数据。"},
			{Type: ProviderEventCompleted},
		},
	}}
	executions := 0
	tool := overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		executions++
		return ToolWait{
			State: models.AIRunStateWaitingUserConsent, EventType: "consent.required",
			ConsentScope: models.AIUserPermissionPersonalDataAccess,
			Payload:      map[string]interface{}{"scope": models.AIUserPermissionPersonalDataAccess},
		}, nil
	}}
	runtime := newToolRuntime(t, db, provider, tool)
	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "分析成绩"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateWaitingUserConsent)

	err = runtime.ResumeRunConsent(context.Background(), 8, run.ID, models.AIUserPermissionPersonalDataAccess, true)
	var runtimeErr *RuntimeError
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_run_not_found", runtimeErr.Code)

	err = runtime.ResumeRunConsent(context.Background(), 7, run.ID, models.AIUserPermissionAcademicCloudStorage, true)
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_run_consent_scope_mismatch", runtimeErr.Code)

	var consentCount int64
	require.NoError(t, db.Model(&models.AIRunConsent{}).Count(&consentCount).Error)
	require.Zero(t, consentCount)
	require.Len(t, provider.Requests(), 1)

	require.NoError(t, runtime.ResumeRunConsent(context.Background(), 7, run.ID, models.AIUserPermissionPersonalDataAccess, false))
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Len(t, provider.Requests(), 2)
	require.Equal(t, 1, executions)
	require.JSONEq(t,
		`{"status":"completed","consent_granted":false,"scope":"ai_personal_data_access","instruction":"用户拒绝了本次访问，不要再次请求或假设可读取该数据"}`,
		provider.Requests()[1].Messages[3].Content,
	)
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

func TestExtractPersonalDataEvidenceKeepsSanitizedHy3AcademicInput(t *testing.T) {
	result := json.RawMessage(`{
		"source":"hy3_mcp",
		"analysis_input":{
			"courses":[{"course_name":"信号与系统","grade":58,"credits":3,"is_required":true,"passed":false,"student_id":"2400000000"}],
			"earned_credits":25.5,"required_credits":25.5,"erke_earned":0,"erke_required":0,
			"password":"secret","cookie":"private"
		}
	}`)

	evidence := extractPersonalDataEvidence(result)
	require.Len(t, evidence, 1)
	require.Equal(t, "hy3_mcp", evidence[0].Source)
	require.Equal(t, "academic_analysis", evidence[0].Dataset)
	require.Equal(t, "信号与系统", evidence[0].AnalysisInput["courses"].([]map[string]interface{})[0]["course_name"])
	payload, err := json.Marshal(evidence)
	require.NoError(t, err)
	require.NotContains(t, string(payload), "student_id")
	require.NotContains(t, string(payload), "password")
	require.NotContains(t, string(payload), "cookie")
	require.NotContains(t, string(payload), "2400000000")
}

func TestAcademicToolResultForModelUsesChineseWhitelist(t *testing.T) {
	raw := json.RawMessage(`{
		"status":"ok",
		"analysis":{"risk_summary":"failed_required_credits 为0，后续补考或重修","priority_actions":["补考"]},
		"deterministic_findings":{
			"failed_course_count":2,"failed_required_credits":6,"earned_credits":25.5,
			"credit_gap":0,"erke_gap":0,"unknown_grade_course_count":0,
			"missing_credit_course_count":0,"data_completeness_percent":100,
			"failed_courses":["信号与系统","计算机网络"]
		},
		"analysis_input":{
			"courses":[{"course_name":"信号与系统","grade":58,"credits":3,"is_required":true,"passed":false}],
			"earned_credits":25.5,"required_credits":25.5,"erke_earned":0,"erke_required":0
		},
		"warnings":[]
	}`)

	result := toolResultForModel("hy3_decision_analyze_academic", raw)
	require.JSONEq(t, `{
		"status":"ok",
		"学业结论":{
			"未通过课程数":2,"未通过必修课程涉及学分":6,"已获得学分":25.5,
			"总学分缺口":0,"二课学分缺口":0,"成绩未知课程数":0,
			"学分未知课程数":0,"数据完整度百分比":100,
			"未通过课程":["信号与系统","计算机网络"]
		},
		"分析依据":{
			"课程":[{"课程名称":"信号与系统","成绩":58,"学分":3,"课程性质":"必修","状态":"未通过"}],
			"已获得学分":25.5,"要求学分":25.5,"已获得二课学分":0,"要求二课学分":0
		},
		"warnings":[]
	}`, string(result))
	require.NotContains(t, string(result), "risk_summary")
	require.NotContains(t, string(result), "credit_gap")
	require.NotContains(t, string(result), "failed_required_credits")
	require.NotContains(t, string(result), "后续补考或重修")
}

func TestAcademicCitationFallbackKeepsPersonalGradeFacts(t *testing.T) {
	raw := json.RawMessage(`{
		"status":"ok","is_stale":true,
		"analysis_input":{
			"courses":[
				{"course_name":"信号与系统","grade":55.8,"credits":3.5,"is_required":false,"passed":false},
				{"course_name":"电磁场与电磁波","grade":60.1,"credits":2.5,"is_required":false,"passed":true}
			],
			"earned_credits":25.5,"required_credits":25.5
		}
	}`)

	fallback := academicCitationFallback("hy3_decision_analyze_academic", raw)
	require.Contains(t, fallback, "已成功读取你的个人成绩")
	require.Contains(t, fallback, "《信号与系统》成绩 55.8、3.5 学分")
	require.NotContains(t, fallback, "电磁场与电磁波")
	require.Contains(t, fallback, "25.5 / 25.5")
	require.Contains(t, fallback, "成绩快照已过期")
	require.Contains(t, fallback, "个人成绩结论不受影响")
	require.NotContains(t, fallback, "应参加补考")
	require.NotContains(t, fallback, "可以申请重修")
}
