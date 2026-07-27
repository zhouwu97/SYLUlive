package ai

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type fixedRetriever struct {
	result RetrievalResult
	err    error
}

type recordingRetriever struct {
	fixedRetriever
	query chan string
}

func (r recordingRetriever) Retrieve(ctx context.Context, query string) (RetrievalResult, error) {
	r.query <- query
	return r.fixedRetriever.Retrieve(ctx, query)
}

func (r fixedRetriever) Retrieve(context.Context, string) (RetrievalResult, error) {
	return r.result, r.err
}

func newRuntimeTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", uuid.NewString())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	require.NoError(t, db.AutoMigrate(
		&models.AIConversation{}, &models.AIConversationMessage{}, &models.AIRun{},
		&models.AIEvent{}, &models.AIToolCall{}, &models.AIRunResumeJob{}, &models.AIQuotaEntry{},
		&models.AIUserBudget{}, &models.AIBudgetReservation{}, &models.AIUsageRecord{}, &models.DeviceToolJob{},
		&models.AIRunConsent{},
	))
	return db
}

func newTestRuntime(t *testing.T, db *gorm.DB, provider AIProvider, retriever PolicyRetriever) *Runtime {
	t.Helper()
	runtime, err := NewRuntime(db, provider, retriever, NewEventBroker(), RuntimeConfig{
		ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
		MaxToolSteps:    3,
		MaxMessageChars: 20, HourlyMessageLimit: 3,
		DefaultBudgetLimitMicroYuan: 1_000_000, ReservationMicroYuan: 10_000,
		InputPriceMicroYuanPerMillion: 1_000_000, OutputPriceMicroYuanPerMillion: 1_000_000,
		AuditHashSecret: "test-secret",
	})
	require.NoError(t, err)
	return runtime
}

func waitRunState(t *testing.T, db *gorm.DB, runID string, states ...string) models.AIRun {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		var run models.AIRun
		if err := db.First(&run, "id = ?", runID).Error; err == nil {
			for _, state := range states {
				if run.State == state {
					return run
				}
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("run %s did not reach states %v", runID, states)
	return models.AIRun{}
}

func TestNormalizeUserMessageCountsGraphemeClusters(t *testing.T) {
	message, count, err := NormalizeUserMessage("  👨‍👩‍👧‍👦\n\n请假  ", 4)
	require.NoError(t, err)
	require.Equal(t, "👨‍👩‍👧‍👦 请假", message)
	require.Equal(t, 4, count)
	_, _, err = NormalizeUserMessage("一二三四", 3)
	var runtimeErr *RuntimeError
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_message_too_long", runtimeErr.Code)
}

func TestBuildPolicyPromptAddsDirectGPAAnswerGuidance(t *testing.T) {
	gpaPlan := BuildPolicyQueryPlan("GPA")
	prompt := buildPolicyPrompt("GPA", gpaPlan, PolicyEvidenceCoverage{}, nil)
	require.Contains(t, prompt, "先用一句话解释 GPA")
	require.Contains(t, prompt, "GPA = Σ(课程绩点×课程学分) / Σ课程学分")
	require.Contains(t, prompt, "不得编造校内换算表")
	generalPlan := BuildPolicyQueryPlan("怎么请假")
	generalPrompt := buildPolicyPrompt("怎么请假", generalPlan, PolicyEvidenceCoverage{}, nil)
	require.Contains(t, generalPrompt, "第一句直接给出定义、结论或办理方向")
	require.Contains(t, generalPrompt, "除非用户明确要求比较，否则不要使用表格")
	require.NotContains(t, generalPrompt, "GPA =")
	require.NotContains(t, generalPrompt, "识别意图")
	require.Contains(t, campusAgentSystemPrompt, "不得用弱相关材料拼表格")
}

func TestBuildPolicyPromptDoesNotHardcodeMakeupExamFormula(t *testing.T) {
	plan := BuildPolicyQueryPlan("补考成绩怎么算")
	prompt := buildPolicyPrompt("补考成绩怎么算", plan, PolicyEvidenceCoverage{}, nil)
	require.Contains(t, prompt, "识别意图："+PolicyIntentSecondExamGrade)
	require.Contains(t, prompt, "不得自行给出平时成绩与卷面成绩的合成比例")
	require.Contains(t, prompt, "必须引用，但每一条都要写明来自历史版本")
	require.NotContains(t, prompt, "补考总成绩 = 原平时成绩对应部分")
	require.NotContains(t, prompt, "等级为D或F")
	require.NotContains(t, prompt, "绩点为1或0")
}

func TestBuildPolicyPromptDemandsFailedCourseBranchesAndReportsGaps(t *testing.T) {
	plan := BuildPolicyQueryPlan("挂科了怎么办")
	chunks := []RetrievedChunk{
		{ChunkID: 1, DocumentID: 10, DocumentType: DocTypeStatusPolicy, Content: "首次考核不合格"},
		{ChunkID: 2, DocumentID: 11, DocumentType: DocTypeHistoricalSecondExam, Content: "历史二考细则"},
	}
	coverage := evaluatePolicyEvidenceCoverage(plan, chunks)
	prompt := buildPolicyPrompt("挂科了怎么办", plan, coverage, chunks)

	require.Contains(t, prompt, "识别意图："+PolicyIntentFailedCourse)
	require.Contains(t, prompt, "1. 首次考核不合格后的当前处理方向")
	require.Contains(t, prompt, "3. 不适用或未通过二次考试后的重修处理")
	require.Contains(t, prompt, "4. 实验、实践、课程设计等特殊课程的边界")
	require.Contains(t, prompt, "- 现行学籍规则：有")
	require.Contains(t, prompt, "- 现行重修规则：无")
	require.Contains(t, prompt, "缺少现行重修依据")
	require.Contains(t, prompt, "未召回：现行课程重修管理办法")
	require.Contains(t, prompt, "历史资料只能补充现行文件未明确的环节")
	require.Contains(t, prompt, `doc_type="`+DocTypeHistoricalSecondExam+`" version="历史版本"`)
	require.Contains(t, prompt, `doc_type="`+DocTypeStatusPolicy+`" version="现行"`)
	require.Contains(t, policySystemPrompt, "不得承诺可以参加普通补考")
}

func TestBuildPolicyPromptForbidsHistoryOnRetakeQuestions(t *testing.T) {
	plan := BuildPolicyQueryPlan("重修有什么规定")
	prompt := buildPolicyPrompt("重修有什么规定", plan, PolicyEvidenceCoverage{}, nil)
	require.Contains(t, prompt, "不得用历史二次考试细则替代现行重修办法")
	require.Contains(t, prompt, "不得引用历史版本的补考或重修细则")
}

func TestRuntimePassesOriginalQuestionAndCoversRetakeBranch(t *testing.T) {
	db := newRuntimeTestDB(t)
	queries := make(chan string, 1)
	// 检索计划已经移入 Retriever，Runtime 只传原始问题；扩展在 HybridRetriever 内完成。
	retriever := recordingRetriever{
		fixedRetriever: fixedRetriever{result: RetrievalResult{
			Plan: BuildPolicyQueryPlan("挂科了怎么办"),
			Chunks: []RetrievedChunk{
				{ChunkID: 1, DocumentID: 10, DocumentType: DocTypeStatusPolicy, Title: "学籍管理规定",
					Content: "课程首次考核不合格的，参加二次考试或重新学习", RRFScore: 0.05},
				{ChunkID: 2, DocumentID: 12, DocumentType: DocTypeRetakePolicy, Title: "课程重修管理办法",
					Content: "未取得学分的课程可以申请重修", RRFScore: 0.01},
			},
		}},
		query: queries,
	}
	provider := &MockProvider{Response: ChatResponse{Content: "先看二次考试[chunk:1]，未通过则重修[chunk:2]。"}}
	runtime := newTestRuntime(t, db, provider, retriever)
	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{
		ClientRequestID: uuid.NewString(), Message: "挂科了怎么办",
	})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)

	require.Equal(t, "挂科了怎么办", <-queries)
	require.Len(t, provider.Requests, 1)
	userPrompt := provider.Requests[0].Messages[1].Content
	require.Contains(t, userPrompt, "识别意图："+PolicyIntentFailedCourse)
	require.Contains(t, userPrompt, "- 现行重修规则：有")
	require.Contains(t, userPrompt, "<evidence chunk_id=\"2\"")
}

func TestRuntimeIdempotencyQuotaAndCitationCompletion(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &MockProvider{Response: ChatResponse{Content: "请按规定办理。[chunk:1]", InputTokens: 20, OutputTokens: 8}}
	retriever := fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
		ChunkID: 1, DocumentID: 9, Content: "请假需审批", Title: "学生手册", RRFScore: 0.05,
	}}}}
	runtime := newTestRuntime(t, db, provider, retriever)
	requestID := uuid.NewString()
	run, duplicate, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: requestID, Message: "怎么请假"})
	require.NoError(t, err)
	require.False(t, duplicate)
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)

	duplicateRun, duplicate, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: requestID, Message: "不同文本"})
	require.NoError(t, err)
	require.True(t, duplicate)
	require.Equal(t, run.ID, duplicateRun.ID)

	for index := 0; index < 2; index++ {
		created, _, createErr := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请假规定"})
		require.NoError(t, createErr)
		waitRunState(t, db, created.ID, models.AIRunStateCompleted)
	}
	_, _, err = runtime.CreateRun(context.Background(), 7, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "还能问吗"})
	var runtimeErr *RuntimeError
	require.ErrorAs(t, err, &runtimeErr)
	require.Equal(t, "ai_quota_exceeded", runtimeErr.Code)

	_, err = runtime.GetRun(context.Background(), 8, run.ID)
	require.Error(t, err)
	var messages []models.AIConversationMessage
	require.NoError(t, db.Where("run_id = ?", run.ID).Order("created_at ASC").Find(&messages).Error)
	require.Len(t, messages, 2)
	require.Contains(t, messages[1].Content, "[chunk:1]")
}

func TestRuntimeQuotaExemptionAppliesOnlyToConfiguredUser(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime, err := NewRuntime(
		db,
		&MockProvider{Response: ChatResponse{Content: "测试回答。[chunk:1]"}},
		fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{
			ChunkID: 1, DocumentID: 1, Content: "测试资料", Title: "测试资料",
		}}}},
		NewEventBroker(),
		RuntimeConfig{
			ProviderName: "mock", Model: "mock", RequestTimeout: 5 * time.Second,
			MaxToolSteps: 3, MaxMessageChars: 20, HourlyMessageLimit: 3,
			QuotaExemptUserIDs:             []uint{2},
			DefaultBudgetLimitMicroYuan:    1_000_000,
			ReservationMicroYuan:           10_000,
			InputPriceMicroYuanPerMillion:  1_000_000,
			OutputPriceMicroYuanPerMillion: 1_000_000,
			AuditHashSecret:                "test-secret",
		},
	)
	require.NoError(t, err)

	for index := 0; index < 4; index++ {
		run, _, createErr := runtime.CreateRun(context.Background(), 2, CreateRunRequest{
			ClientRequestID: uuid.NewString(), Message: "测试账号提问",
		})
		require.NoError(t, createErr)
		waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	}
	require.True(t, runtime.IsQuotaExempt(2))
	require.False(t, runtime.IsQuotaExempt(3))
	remaining, resetAt, err := runtime.Quota(context.Background(), 2)
	require.NoError(t, err)
	require.Equal(t, 3, remaining)
	require.Nil(t, resetAt)
}

func TestRuntimeReleasesQuotaAndBudgetBeforeGeneration(t *testing.T) {
	db := newRuntimeTestDB(t)
	runtime := newTestRuntime(t, db, &MockProvider{}, fixedRetriever{err: ErrRetrievalUnavailable})
	run, _, err := runtime.CreateRun(context.Background(), 11, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请假规定"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateFailed)
	remaining, _, err := runtime.Quota(context.Background(), 11)
	require.NoError(t, err)
	require.Equal(t, 3, remaining)
	var budget models.AIUserBudget
	require.NoError(t, db.First(&budget, "user_id = ?", 11).Error)
	require.Zero(t, budget.ReservedMicroYuan)
}

type blockingProvider struct{}

func (blockingProvider) Name() string { return "blocking" }
func (blockingProvider) Capabilities() ProviderCapabilities {
	return ProviderCapabilities{Streaming: true}
}
func (blockingProvider) Start(context.Context, ProviderRequest) (ProviderStream, error) {
	return blockingStream{}, nil
}

type blockingStream struct{}

func (blockingStream) Next(ctx context.Context) (ProviderEvent, error) {
	<-ctx.Done()
	return ProviderEvent{}, ctx.Err()
}
func (blockingStream) Close() error { return nil }

func TestRuntimeCancelStopsProviderAndDoesNotConsumePreGenerationQuota(t *testing.T) {
	db := newRuntimeTestDB(t)
	retriever := fixedRetriever{result: RetrievalResult{Chunks: []RetrievedChunk{{ChunkID: 1, DocumentID: 1, Content: "规则", Title: "手册"}}}}
	runtime := newTestRuntime(t, db, blockingProvider{}, retriever)
	run, _, err := runtime.CreateRun(context.Background(), 13, CreateRunRequest{ClientRequestID: uuid.NewString(), Message: "请假规定"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateGenerating)
	_, err = runtime.Cancel(context.Background(), 13, run.ID)
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateCancelled)
	require.Eventually(t, func() bool {
		remaining, _, quotaErr := runtime.Quota(context.Background(), 13)
		return quotaErr == nil && remaining == 3
	}, time.Second, 10*time.Millisecond)
}

func TestProviderErrorClassPreservesKnownClassification(t *testing.T) {
	err := &ProviderError{Class: ProviderErrorRateLimited, Err: errors.New("remote detail")}
	require.Equal(t, ProviderErrorRateLimited, providerErrorClass(err))
	require.NotContains(t, err.Error(), "remote detail")
}
