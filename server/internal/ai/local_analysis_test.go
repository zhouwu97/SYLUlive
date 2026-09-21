package ai

import (
	"context"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
	"testing"
	"time"
)

func TestLocalAnalysisDoesNotPersistPersonalContent(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &MockProvider{Response: ChatResponse{Content: "本次私密分析回答", InputTokens: 20, OutputTokens: 10}}
	runtime := newTestRuntime(t, db, provider, fixedRetriever{})
	input := LocalAnalysisRequest{Question: "本次私密问题", Summary: LocalAnalysisSummary{Kind: "grade_statistics", CourseCount: 5, Credits: 12}, DataTime: time.Now()}
	input.Consent.Accepted = true
	input.Consent.AcceptedAt = time.Now()
	input.Consent.RequestID = uuid.NewString()
	var events []string
	require.NoError(t, runtime.LocalAnalysis(context.Background(), 1, input, func(event string, payload interface{}) error { events = append(events, event); return nil }))
	require.Contains(t, events, "answer.delta")
	require.Contains(t, events, "run.completed")
	for _, model := range []interface{}{&models.AIConversation{}, &models.AIConversationMessage{}, &models.AIRun{}, &models.AIEvent{}} {
		var count int64
		require.NoError(t, db.Model(model).Count(&count).Error)
		require.Zero(t, count)
	}
	var usage models.AIUsageRecord
	require.NoError(t, db.First(&usage).Error)
	require.Equal(t, "local_analysis", usage.Purpose)
	var quota models.AIQuotaEntry
	require.NoError(t, db.First(&quota).Error)
	require.Equal(t, "consumed", quota.Status)
	require.Error(t, runtime.LocalAnalysis(context.Background(), 1, input, func(string, interface{}) error { return nil }))
	require.Len(t, provider.Requests, 1)
}
func TestLocalAnalysisRequiresFreshConsentBeforeProvider(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &MockProvider{}
	runtime := newTestRuntime(t, db, provider, fixedRetriever{})
	input := LocalAnalysisRequest{Question: "分析成绩", Summary: LocalAnalysisSummary{Kind: "grade_statistics", CourseCount: 5, Credits: 12}, DataTime: time.Now()}
	input.Consent.RequestID = uuid.NewString()
	require.Error(t, runtime.LocalAnalysis(context.Background(), 1, input, func(string, interface{}) error { return nil }))
	require.Empty(t, provider.Requests)
	var count int64
	require.NoError(t, db.Model(&models.AIQuotaEntry{}).Count(&count).Error)
	require.Zero(t, count)
}
