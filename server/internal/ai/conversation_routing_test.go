package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

func TestConversationRoutingKeepsChatAndCampusQuestions(t *testing.T) {
	for _, message := range []string{"我今天有点累，想随便聊聊", "帮我写一首关于夏天的诗", "解释一下递归", "what can you do", "推荐一本科幻小说"} {
		require.False(t, needsCampusConversationContext(message, nil), message)
	}
	for _, message := range []string{"学校图书馆几点关门", "怎么请假", "我的成绩怎么样", "明天有课吗", "分析我的学业情况", "最近有什么竞赛", "查看我的日程"} {
		require.True(t, needsCampusConversationContext(message, nil), message)
	}
	history := []PolicyRAGHistoryMessage{{Role: "user", Content: "补考成绩怎么算"}, {Role: "assistant", Content: "需要查看当前规则"}}
	require.True(t, needsCampusConversationContext("那怎么办？", history))
	require.Contains(t, campusConversationRoutingQuery("那怎么办？", history), "补考成绩怎么算")
	require.False(t, needsCampusConversationContext("换个话题，帮我写首诗", history))
}

func TestRuntimeGeneralConversationSkipsCampusDependenciesAndKeepsOwnedHistory(t *testing.T) {
	db := newRuntimeTestDB(t)
	provider := &scriptedToolProvider{rounds: [][]ProviderEvent{{
		{Type: ProviderEventTextDelta, Text: "可以聊聊你喜欢的故事。"},
		{Type: ProviderEventCompleted},
	}}}
	runtime := newToolRuntime(t, db, provider, overviewTool{execute: func(context.Context, uint, json.RawMessage) (interface{}, error) {
		t.Error("普通聊天不得读取个人数据")
		return nil, nil
	}})
	runtime.config.MaxMessageChars = 100
	retriever := &countingRetriever{}
	runtime.retriever = retriever
	conversationID := uuid.NewString()
	require.NoError(t, db.Create(&models.AIConversation{ID: conversationID, UserID: 7}).Error)
	seedPolicyHistoryRound(t, db, 7, conversationID, models.AIRunStateCompleted, "我最近喜欢科幻小说", "你喜欢哪类科幻？", time.Now().Add(-time.Minute))
	seedPolicyHistoryRound(t, db, 88, conversationID, models.AIRunStateCompleted, "其他账号的秘密", "不能读取这条记录", time.Now().Add(-30*time.Second))
	run, _, err := runtime.CreateRun(context.Background(), 7, CreateRunRequest{ConversationID: conversationID, ClientRequestID: uuid.NewString(), Message: "我喜欢太空探索，你呢"})
	require.NoError(t, err)
	waitRunState(t, db, run.ID, models.AIRunStateCompleted)
	require.Zero(t, retriever.Calls())
	requests := provider.Requests()
	require.Len(t, requests, 1)
	require.Empty(t, requests[0].Tools)
	require.Len(t, requests[0].Messages, 4)
	require.Contains(t, requests[0].Messages[0].Content, "自由聊天")
	require.Equal(t, "我最近喜欢科幻小说", requests[0].Messages[1].Content)
	require.Equal(t, "你喜欢哪类科幻？", requests[0].Messages[2].Content)
	require.Equal(t, "我喜欢太空探索，你呢", requests[0].Messages[3].Content)
	serialized, err := json.Marshal(requests)
	require.NoError(t, err)
	require.NotContains(t, string(serialized), "其他账号的秘密")
	require.NotContains(t, requests[0].Messages[3].Content, "已核验证据")
	require.NotContains(t, requests[0].Messages[3].Content, "第一句直接给出")
}
