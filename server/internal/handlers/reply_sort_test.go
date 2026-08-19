package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// performReplyListRequest 请求 GET /api/posts/:id/replies?query=...。
func performReplyListRequest(
	t *testing.T,
	db *gorm.DB,
	postID uint,
	query string,
	userID uint,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	context, _ := gin.CreateTestContext(recorder)
	url := fmt.Sprintf("/api/posts/%d/replies", postID)
	if query != "" {
		url += "?" + query
	}
	context.Request = httptest.NewRequest(http.MethodGet, url, nil)
	context.Params = gin.Params{{Key: "id", Value: fmt.Sprint(postID)}}
	if userID != 0 {
		context.Set("user_id", userID)
	}
	NewReplyHandler(db, "", "").GetList(context)
	return recorder
}

// decodeReplyList 解析 GetList 的对象响应。
func decodeReplyList(t *testing.T, body []byte) replyListResponse {
	t.Helper()
	var resp replyListResponse
	require.NoError(t, json.Unmarshal(body, &resp))
	return resp
}

// replyTestFixture 构造 1 个根评论 + 2 个根的评论数据。
func replyTestFixture(t *testing.T, db *gorm.DB) (uint, []models.Reply) {
	t.Helper()
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	now := time.Now()
	post := models.Post{
		Title:          "排序测试帖",
		Content:        "正文",
		BoardID:        models.BoardShuitie,
		AuthorID:       1,
		ContentKind:    models.PostContentKindNormal,
		Status:         models.PostStatusNormal,
		CreatedAt:      now,
		LastActivityAt: now,
	}
	require.NoError(t, db.Create(&post).Error)

	// root A：老、高赞（hot 应该排第一）
	rootA := models.Reply{PostID: post.ID, AuthorID: 1, Content: "老高赞", Status: models.ReplyStatusNormal, LikeCount: 30, CreatedAt: now.Add(-48 * time.Hour)}
	require.NoError(t, db.Create(&rootA).Error)
	// root B：新、低赞
	rootB := models.Reply{PostID: post.ID, AuthorID: 2, Content: "新低赞", Status: models.ReplyStatusNormal, LikeCount: 1, CreatedAt: now.Add(-time.Hour)}
	require.NoError(t, db.Create(&rootB).Error)
	// root A 的子回复（时间乱序，验证子回复永远 ASC）
	childA1 := models.Reply{PostID: post.ID, ParentReplyID: &rootA.ID, AuthorID: 2, Content: "A 子1", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-20 * time.Hour)}
	childA2 := models.Reply{PostID: post.ID, ParentReplyID: &rootA.ID, AuthorID: 1, Content: "A 子2", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-30 * time.Hour)}
	require.NoError(t, db.Create(&childA1).Error)
	require.NoError(t, db.Create(&childA2).Error)
	// 已删除回复：不进入结果
	deleted := models.Reply{PostID: post.ID, AuthorID: 1, Content: "已删除", Status: models.ReplyStatusDeleted, CreatedAt: now}
	require.NoError(t, db.Create(&deleted).Error)

	// 点赞 rootB（user 2 点赞了 rootB）
	require.NoError(t, db.Create(&models.Like{UserID: 2, TargetType: "reply", TargetID: rootB.ID}).Error)
	rootB.LikeCount = 1
	require.NoError(t, db.Model(&rootB).Update("like_count", 1).Error)

	return post.ID, []models.Reply{rootA, rootB, childA1, childA2}
}

// 默认（不传 sort）→ hot。
func TestReplyListDefaultSortIsHot(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	recorder := performReplyListRequest(t, db, postID, "", 0)
	require.Equal(t, http.StatusOK, recorder.Code)

	resp := decodeReplyList(t, recorder.Body.Bytes())
	replies := resp.Replies
	require.Len(t, replies, 4, "deleted 回复不应进入结果")
	require.EqualValues(t, 4, resp.Total)
	// hot：rootA（30赞）在 rootB（1赞）之前。
	require.Equal(t, "老高赞", replies[0].Content)
	require.Equal(t, "A 子2", replies[1].Content)
	require.Equal(t, "A 子1", replies[2].Content)
	require.Equal(t, "新低赞", replies[3].Content)
}

// sort=hot → root 热门排序。
func TestReplyListSortHot(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	recorder := performReplyListRequest(t, db, postID, "sort=hot", 0)
	require.Equal(t, http.StatusOK, recorder.Code)

	replies := decodeReplyList(t, recorder.Body.Bytes()).Replies
	require.Equal(t, "老高赞", replies[0].Content)
	require.Equal(t, "A 子2", replies[1].Content)
	require.Equal(t, "A 子1", replies[2].Content)
	require.Equal(t, "新低赞", replies[3].Content)
}

// sort=latest → root 时间 DESC。
func TestReplyListSortLatest(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	recorder := performReplyListRequest(t, db, postID, "sort=latest", 0)
	require.Equal(t, http.StatusOK, recorder.Code)

	replies := decodeReplyList(t, recorder.Body.Bytes()).Replies
	// latest：rootB（新）在 rootA（旧）之前。
	require.Equal(t, "新低赞", replies[0].Content)
	require.Equal(t, "老高赞", replies[1].Content)
	// 子回复依然 ASC（childA2 更早 → 在前）。
	require.Equal(t, "A 子2", replies[2].Content)
	require.Equal(t, "A 子1", replies[3].Content)
}

// sort=xxx → 400。
func TestReplyListInvalidSortReturns400(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	recorder := performReplyListRequest(t, db, postID, "sort=top", 0)
	require.Equal(t, http.StatusBadRequest, recorder.Code)
	body := recorder.Body.String()
	require.Contains(t, body, "无效的评论排序方式")
}

// 登录用户 → is_liked 正确。
func TestReplyListIsLikedForLoggedInUser(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	// user 2 点赞了 rootB（id 为 fixture 中第 2 个 root）。
	recorder := performReplyListRequest(t, db, postID, "sort=hot", 2)
	require.Equal(t, http.StatusOK, recorder.Code)

	replies := decodeReplyList(t, recorder.Body.Bytes()).Replies
	var rootB models.Reply
	for _, r := range replies {
		if r.Content == "新低赞" {
			rootB = r
		}
	}
	require.True(t, rootB.IsLiked, "user2 点赞过 rootB，应 is_liked=true")
	require.False(t, replies[0].IsLiked, "rootA 未被点赞")
}

// 未登录用户 → 正常读取，is_liked 全 false。
func TestReplyListAnonymousRead(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	recorder := performReplyListRequest(t, db, postID, "sort=hot", 0)
	require.Equal(t, http.StatusOK, recorder.Code)

	replies := decodeReplyList(t, recorder.Body.Bytes()).Replies
	for _, r := range replies {
		require.False(t, r.IsLiked)
	}
}

// 响应是 {replies, total, next_cursor} 对象（分页重构后的稳定形状）。
func TestReplyListResponseShape(t *testing.T) {
	db := newReplyTestDB(t)
	postID, _ := replyTestFixture(t, db)
	recorder := performReplyListRequest(t, db, postID, "sort=hot", 0)
	require.Equal(t, http.StatusOK, recorder.Code)
	body := recorder.Body.String()
	require.True(t, json.Valid([]byte(body)))
	require.True(t, len(body) > 0 && body[0] == '{', "响应应为 JSON 对象")
	require.Contains(t, body, `"replies"`)
	require.Contains(t, body, `"total"`)
	require.Contains(t, body, `"next_cursor"`)
}
