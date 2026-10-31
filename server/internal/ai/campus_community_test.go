package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func communityTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db := newRuntimeTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.Post{}, &models.Reply{}, &models.PostImage{}, &models.ReplyImage{}, &models.File{}))
	return db
}

func communityTestPost(t *testing.T, db *gorm.DB, id uint) models.Post {
	t.Helper()
	post := models.Post{ID: id, BoardID: models.BoardShuitie, AuthorID: 1, Title: "食堂讨论", Content: "今天的菜怎么样", Status: models.PostStatusNormal, Contact: "private-contact", ViewCount: 17, LikeCount: 5}
	require.NoError(t, db.Create(&post).Error)
	return post
}

func communityTestRead(t *testing.T, tools []PureReadTool, name, arguments string) CampusToolResult {
	t.Helper()
	result, err := campusToolByName(t, tools, name).Execute(context.Background(), 7, json.RawMessage(arguments))
	require.NoError(t, err)
	return result.(CampusToolResult)
}

func TestCommunityReadToolsOptInAndPrivacy(t *testing.T) {
	db := communityTestDB(t)
	post := communityTestPost(t, db, 1)
	for _, tool := range NewCampusMCPTools(db, nil, nil) {
		require.NotEqual(t, "community.get_post", tool.Name())
	}
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	result := communityTestRead(t, tools, "community.get_post", `{"post_id":1}`)
	view := result.Data.(communityPostView)
	require.Equal(t, post.ID, view.PostID)
	require.NotEmpty(t, view.SourceVersion)
	raw, err := json.Marshal(result)
	require.NoError(t, err)
	for _, private := range []string{"private-contact", "author_id", "contact", "password", "asset_key", "view_count"} {
		require.NotContains(t, string(raw), private)
	}
	var unchanged models.Post
	require.NoError(t, db.First(&unchanged, post.ID).Error)
	require.Equal(t, post.ViewCount, unchanged.ViewCount)
	require.Equal(t, post.LikeCount, unchanged.LikeCount)
	require.Equal(t, post.ReplyCount, unchanged.ReplyCount)
	require.True(t, post.UpdatedAt.Equal(unchanged.UpdatedAt))
}

func TestCommunityReadVisibilityAndLiteralSearch(t *testing.T) {
	db := communityTestDB(t)
	communityTestPost(t, db, 1)
	communityTestPost(t, db, 2)
	communityTestPost(t, db, 3)
	for index, update := range []map[string]interface{}{
		{"status": models.PostStatusModeratedHidden}, {"status": models.PostStatusDeleted},
		{"status": models.PostStatusClosed}, {"status": "future_private_status"},
		{"board_id": models.BoardMarket}, {"content_kind": models.PostContentKindPoll},
	} {
		post := communityTestPost(t, db, uint(index+10))
		require.NoError(t, db.Model(&post).Updates(update).Error)
	}
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	page := communityTestRead(t, tools, "community.list_feed", `{"limit":2}`).Data.(map[string]interface{})
	items := page["items"].([]communityPostView)
	require.Equal(t, []uint{3, 2}, []uint{items[0].PostID, items[1].PostID})
	require.EqualValues(t, 2, page["next_after_id"])
	page = communityTestRead(t, tools, "community.list_feed", `{"limit":2,"after_id":2}`).Data.(map[string]interface{})
	require.Len(t, page["items"], 1)
	require.EqualValues(t, 0, page["next_after_id"])
	for id := 10; id < 16; id++ {
		_, err := campusToolByName(t, tools, "community.get_post").Execute(context.Background(), 7, json.RawMessage(fmt.Sprintf(`{"post_id":%d}`, id)))
		require.ErrorIs(t, err, gorm.ErrRecordNotFound)
		_, err = campusToolByName(t, tools, "community.list_replies").Execute(context.Background(), 7, json.RawMessage(fmt.Sprintf(`{"post_id":%d}`, id)))
		require.ErrorIs(t, err, gorm.ErrRecordNotFound)
	}
	page = communityTestRead(t, tools, "community.search_posts", `{"query":"%"}`).Data.(map[string]interface{})
	require.Empty(t, page["items"])
	require.NoError(t, db.Model(&models.Post{}).Where("id = 1").Update("content", "涨价 10%_! 吗").Error)
	page = communityTestRead(t, tools, "community.search_posts", `{"query":"%_!"}`).Data.(map[string]interface{})
	require.Len(t, page["items"], 1)
}

func TestCommunityReadSemanticVersionAndTruncation(t *testing.T) {
	db := communityTestDB(t)
	post := communityTestPost(t, db, 1)
	require.NoError(t, db.Model(&post).Update("content", strings.Repeat("校", 10001)).Error)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	read := func() communityPostView {
		return communityTestRead(t, tools, "community.get_post", `{"post_id":1}`).Data.(communityPostView)
	}
	before := read()
	require.True(t, before.Truncated)
	require.LessOrEqual(t, len([]rune(before.Content)), 10003)
	require.NoError(t, db.Model(&post).Updates(map[string]interface{}{"view_count": 99, "like_count": 31, "reply_count": 42}).Error)
	require.Equal(t, before.SourceVersion, read().SourceVersion)
	// 修改被截断的部分，也必须使版本发生变化。
	require.NoError(t, db.Model(&post).Update("content", strings.Repeat("校", 10000)+"园").Error)
	require.NotEqual(t, before.SourceVersion, read().SourceVersion)
}

func TestCommunityReplyContextDeletionAndParentVisibility(t *testing.T) {
	db := communityTestDB(t)
	post := communityTestPost(t, db, 1)
	rootID := uint(1)
	stickerID := "builtin-a"
	root := models.Reply{ID: rootID, PostID: post.ID, AuthorID: 1, Content: "removed-secret", StickerID: &stickerID, Status: models.ReplyStatusDeleted}
	child := models.Reply{ID: 2, PostID: post.ID, AuthorID: 2, ParentReplyID: &rootID, ReplyToReplyID: &rootID, Content: "孩子评论", Status: models.ReplyStatusNormal}
	require.NoError(t, db.Create(&root).Error)
	require.NoError(t, db.Create(&child).Error)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	page := communityTestRead(t, tools, "community.list_replies", `{"post_id":1}`).Data.(map[string]interface{})
	require.Len(t, page["items"], 1)
	result := communityTestRead(t, tools, "community.get_reply_context", `{"reply_id":2}`)
	data := result.Data.(map[string]interface{})
	require.Equal(t, "deleted", data["root_reply"].(communityReplyView).Status)
	raw, err := json.Marshal(result)
	require.NoError(t, err)
	require.NotContains(t, string(raw), "removed-secret")
	require.NotContains(t, string(raw), stickerID)
	_, err = campusToolByName(t, tools, "community.get_reply_context").Execute(context.Background(), 7, json.RawMessage(`{"reply_id":1}`))
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
	_, err = campusToolByName(t, tools, "community.get_reply_context").Execute(context.Background(), 7, json.RawMessage(`{"reply_id":2}`))
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
}

func TestCommunityToolsRejectUnexpectedArgumentsBeforeAudit(t *testing.T) {
	db := communityTestDB(t)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	tool := campusToolByName(t, tools, "community.get_post")
	registry, err := NewToolRegistry(db, tool)
	require.NoError(t, err)
	for _, raw := range []string{`{}`, `null`, `[]`, `{"post_id":0}`, `{"post_id":-1}`, `{"post_id":1.5}`, `{"post_id":null}`, `{"post_id":1,"jwt":"secret"}`, `{"post_id":1}{}`} {
		_, _, err := registry.Execute(context.Background(), "invalid", "run-invalid", 7, tool.Name(), json.RawMessage(raw))
		require.Error(t, err, raw)
	}
	var count int64
	require.NoError(t, db.Model(&models.AIToolCall{}).Count(&count).Error)
	require.Zero(t, count)
	for _, raw := range []string{`{"limit":0}`, `{"limit":21}`, `{"after_id":-1}`, `{"query":null}`, `{"query":" "}`, `{"query":"ok","limit":1.5}`} {
		err := campusToolByName(t, tools, "community.search_posts").(toolArgumentValidator).ValidateToolArguments(json.RawMessage(raw))
		require.Error(t, err, raw)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = tool.Execute(ctx, 7, json.RawMessage(`{"post_id":1}`))
	require.ErrorIs(t, err, context.Canceled)
}

func TestCommunityStickerCatalogCopyFilterAndPagination(t *testing.T) {
	stickers := []CommunitySticker{{ID: "c", Label: "高兴"}, {ID: "a", Label: "高兴"}, {ID: "b", Label: "疑问"}}
	tools := NewCampusMCPTools(nil, nil, nil, WithCampusCommunityReadTools(stickers))
	stickers[0].Label = "changed-after-configuration"
	page := communityTestRead(t, tools, "community.list_stickers", `{"limit":2}`).Data.(map[string]interface{})
	require.Equal(t, []CommunitySticker{{ID: "a", Label: "高兴"}, {ID: "b", Label: "疑问"}}, page["items"])
	require.Equal(t, "b", page["next_after_sticker_id"])
	page = communityTestRead(t, tools, "community.list_stickers", `{"after_sticker_id":"b","limit":2}`).Data.(map[string]interface{})
	require.Equal(t, []CommunitySticker{{ID: "c", Label: "高兴"}}, page["items"])
	require.Empty(t, page["next_after_sticker_id"])
	page = communityTestRead(t, tools, "community.list_stickers", `{"query":"疑问"}`).Data.(map[string]interface{})
	require.Equal(t, []CommunitySticker{{ID: "b", Label: "疑问"}}, page["items"])
}

func TestCommunityPagePreflightRechecksVisibility(t *testing.T) {
	db := communityTestDB(t)
	post := communityTestPost(t, db, 1)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	registry, err := NewToolRegistry(db, tools...)
	require.NoError(t, err)
	runtime := &Runtime{db: db, tools: registry, broker: NewEventBroker()}
	envelope := &AgentContextEnvelope{Entrypoint: "post_detail", ContextRefs: []AgentContextRef{{Type: "post", ID: "1"}}}
	_, err = runtime.validateAgentContext(context.Background(), 7, envelope)
	require.NoError(t, err)
	withoutTools := &Runtime{db: db}
	_, err = withoutTools.validateAgentContext(context.Background(), 7, envelope)
	require.Error(t, err)
	raw, err := json.Marshal(envelope)
	require.NoError(t, err)
	run := &models.AIRun{ID: "community-preflight", ClientRequestID: "community-preflight", UserID: 7, State: models.AIRunStateRetrieving, AgentContext: datatypes.JSON(raw)}
	require.NoError(t, db.Create(run).Error)
	messages, err := runtime.agentContextPreflight(context.Background(), run)
	require.NoError(t, err)
	require.Len(t, messages, 4)
	require.Contains(t, messages[1].Content, "今天的菜怎么样")
	require.Contains(t, messages[1].Content, "untrusted")
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
	_, err = runtime.validateAgentContext(context.Background(), 7, envelope)
	require.Error(t, err)
	// 用新的 Run 验证读取前重新检查，不复用前一次 Run 的工具结果。
	run.ID = "community-preflight-hidden"
	run.ClientRequestID = run.ID
	run.LastEventSeq = 0
	require.NoError(t, db.Create(run).Error)
	messages, err = runtime.agentContextPreflight(context.Background(), run)
	require.Error(t, err)
	for _, message := range messages {
		require.NotContains(t, message.Content, "今天的菜怎么样")
	}
}

func TestCommunityCachedReadCannotReplayHiddenOrEditedSource(t *testing.T) {
	db := communityTestDB(t)
	post := communityTestPost(t, db, 1)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	registry, err := NewToolRegistry(db, tools...)
	require.NoError(t, err)
	read := func() (ToolExecutionResult, bool, error) {
		return registry.Execute(context.Background(), "community-cache", "community-cache-run", 7, "community.get_post", json.RawMessage(`{"post_id":1}`))
	}
	_, cached, err := read()
	require.NoError(t, err)
	require.False(t, cached)
	require.NoError(t, db.Model(&post).Update("view_count", 30).Error)
	_, cached, err = read()
	require.NoError(t, err)
	require.True(t, cached)
	require.NoError(t, db.Model(&post).Update("content", "正文已更新").Error)
	result, _, err := read()
	require.ErrorIs(t, err, ErrStaleToolResult)
	require.Empty(t, result.Result)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
	result, _, err = read()
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
	require.Empty(t, result.Result)
}

func TestCommunityPreciseReplyTargetAndReplyPage(t *testing.T) {
	db := communityTestDB(t)
	post := communityTestPost(t, db, 1)
	rootID, targetID := uint(1), uint(2)
	require.NoError(t, db.Create(&models.Reply{ID: rootID, PostID: post.ID, AuthorID: 1, Content: "根评论"}).Error)
	require.NoError(t, db.Create(&models.Reply{ID: targetID, PostID: post.ID, AuthorID: 2, ParentReplyID: &rootID, Content: "精确目标正文"}).Error)
	require.NoError(t, db.Create(&models.Reply{ID: 3, PostID: post.ID, AuthorID: 3, ParentReplyID: &rootID, ReplyToReplyID: &targetID, Content: "回复目标"}).Error)
	tools := NewCampusMCPTools(db, nil, nil, WithCampusCommunityReadTools(nil))
	data := communityTestRead(t, tools, "community.get_reply_context", `{"reply_id":3}`).Data.(map[string]interface{})
	require.Equal(t, "精确目标正文", data["target_reply"].(communityReplyView).Content)
	require.NoError(t, db.Model(&models.Reply{}).Where("id = ?", targetID).Update("status", models.ReplyStatusDeleted).Error)
	data = communityTestRead(t, tools, "community.get_reply_context", `{"reply_id":3}`).Data.(map[string]interface{})
	require.Empty(t, data["target_reply"].(communityReplyView).Content)
	page := communityTestRead(t, tools, "community.list_replies", `{"post_id":1,"limit":1}`).Data.(map[string]interface{})
	require.EqualValues(t, rootID, page["next_after_id"])
	page = communityTestRead(t, tools, "community.list_replies", `{"post_id":1,"limit":1,"after_id":1}`).Data.(map[string]interface{})
	require.EqualValues(t, 3, page["items"].([]communityReplyView)[0].ReplyID)
	require.EqualValues(t, 0, page["next_after_id"])
	registry, err := NewToolRegistry(db, tools...)
	require.NoError(t, err)
	runtime := &Runtime{db: db, tools: registry}
	envelope := &AgentContextEnvelope{Entrypoint: "reply_detail", ContextRefs: []AgentContextRef{{Type: "reply", ID: "3"}}}
	_, err = runtime.validateAgentContext(context.Background(), 7, envelope)
	require.NoError(t, err)
	calls := agentContextPreflightCalls(*envelope)
	require.Len(t, calls, 1)
	require.Equal(t, "community.get_reply_context", calls[0].name)
	// 损坏或跨帖的精确目标不能被当成当前线程的事实带出。
	other := communityTestPost(t, db, 2)
	require.NoError(t, db.Model(&models.Reply{}).Where("id = ?", targetID).Update("post_id", other.ID).Error)
	_, err = campusToolByName(t, tools, "community.get_reply_context").Execute(context.Background(), 7, json.RawMessage(`{"reply_id":3}`))
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
}

func TestCommunityCapabilitiesAdvertisedOnlyWhenAvailable(t *testing.T) {
	db := communityTestDB(t)
	for _, enabled := range []bool{false, true} {
		var options []CampusMCPOption
		if enabled {
			options = append(options, WithCampusCommunityReadTools(nil))
		}
		registry, err := NewToolRegistry(db, NewCampusMCPTools(db, nil, nil, options...)...)
		require.NoError(t, err)
		capabilities := NewAgentCapabilityRegistry(registry).Public()
		for _, capability := range capabilities {
			if capability.ID == "community.read" {
				require.Equal(t, enabled, capability.Available)
			}
		}
		found := false
		for _, capability := range RetrieveCapabilities("阅读帖子和评论并选择表情", capabilities, nil, 3) {
			found = found || capability.ID == "community.read"
		}
		require.Equal(t, enabled, found)
	}
}
