package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// performReplyCreateRequestAs 以指定用户身份创建回复。
func performReplyCreateRequestAs(
	t *testing.T,
	db *gorm.DB,
	postID uint,
	userID uint,
	form url.Values,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(
		http.MethodPost,
		fmt.Sprintf("/api/posts/%d/replies", postID),
		strings.NewReader(form.Encode()),
	)
	ctx.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	ctx.Params = gin.Params{{Key: "id", Value: fmt.Sprint(postID)}}
	ctx.Set("user_id", userID)
	NewReplyHandler(db, "", "").Create(ctx)
	return recorder
}

// performDeleteReplyRequest 以指定用户身份删除回复。
func performDeleteReplyRequest(
	t *testing.T,
	db *gorm.DB,
	replyID uint,
	userID uint,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(http.MethodDelete, fmt.Sprintf("/api/replies/%d", replyID), nil)
	ctx.Params = gin.Params{{Key: "id", Value: fmt.Sprint(replyID)}}
	ctx.Set("user_id", userID)
	NewReplyHandler(db, "", "").Delete(ctx)
	return recorder
}

// performGetChildrenRequest 请求 GET /api/posts/:id/replies/:replyId/children。
func performGetChildrenRequest(
	t *testing.T,
	db *gorm.DB,
	postID, replyID uint,
	query string,
	userID uint,
) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	url := fmt.Sprintf("/api/posts/%d/replies/%d/children", postID, replyID)
	if query != "" {
		url += "?" + query
	}
	ctx.Request = httptest.NewRequest(http.MethodGet, url, nil)
	ctx.Params = gin.Params{
		{Key: "id", Value: fmt.Sprint(postID)},
		{Key: "replyId", Value: fmt.Sprint(replyID)},
	}
	if userID != 0 {
		ctx.Set("user_id", userID)
	}
	NewReplyHandler(db, "", "").GetChildren(ctx)
	return recorder
}

// TestReplyListTombstoneRootKeepsChildren 删除一级评论后：
// 其正常子回复不再变成"幽灵评论"——根以 tombstone（status=deleted）返回，
// 子回复保留可见，total 与帖子 reply_count 口径一致。
func TestReplyListTombstoneRootKeepsChildren(t *testing.T) {
	db := newReplyTestDB(t)
	createMessageTestUser(t, db, 1, "Alice")
	createMessageTestUser(t, db, 2, "Bob")
	now := time.Now()
	post := models.Post{
		Title: "幽灵评论测试帖", Content: "正文",
		BoardID: models.BoardShuitie, AuthorID: 1,
		ContentKind: models.PostContentKindNormal,
		Status: models.PostStatusNormal,
		CreatedAt: now, LastActivityAt: now,
	}
	require.NoError(t, db.Create(&post).Error)

	root := models.Reply{PostID: post.ID, AuthorID: 2, Content: "root", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-time.Hour)}
	require.NoError(t, db.Create(&root).Error)
	child1 := models.Reply{PostID: post.ID, ParentReplyID: &root.ID, AuthorID: 1, Content: "c1", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-30 * time.Minute)}
	child2 := models.Reply{PostID: post.ID, ParentReplyID: &root.ID, AuthorID: 2, Content: "c2", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-10 * time.Minute)}
	require.NoError(t, db.Create(&child1).Error)
	require.NoError(t, db.Create(&child2).Error)
	require.NoError(t, db.Model(&post).Update("reply_count", 3).Error)

	// 作者删除 root。
	rec := performDeleteReplyRequest(t, db, root.ID, 2)
	require.Equal(t, http.StatusOK, rec.Code)

	// 帖子计数 = 2 正常子回复 + 1 tombstone 根 = 3。
	var reloaded models.Post
	require.NoError(t, db.First(&reloaded, post.ID).Error)
	require.Equal(t, 3, reloaded.ReplyCount)

	// 列表仍能看到 tombstone 根 + 2 条子回复。
	listRec := performReplyListRequest(t, db, post.ID, "sort=latest", 0)
	require.Equal(t, http.StatusOK, listRec.Code)
	resp := decodeReplyList(t, listRec.Body.Bytes())
	require.Len(t, resp.Replies, 3)
	require.Equal(t, models.ReplyStatusDeleted, resp.Replies[0].Status, "根应作为 tombstone 返回")
	contents := map[string]bool{}
	for _, r := range resp.Replies[1:] {
		contents[r.Content] = true
	}
	require.True(t, contents["c1"] && contents["c2"], "子回复应保留可见")
	require.EqualValues(t, 3, resp.Total)

	// children 懒加载接口对 tombstone 根同样可用。
	childrenRec := performGetChildrenRequest(t, db, post.ID, root.ID, "", 0)
	require.Equal(t, http.StatusOK, childrenRec.Code)
	var childrenResp struct {
		Replies    []models.Reply `json:"replies"`
		NextCursor string         `json:"next_cursor"`
	}
	require.NoError(t, json.Unmarshal(childrenRec.Body.Bytes(), &childrenResp))
	require.Len(t, childrenResp.Replies, 2)
}

// TestReplyListRootPagination 根评论游标分页：limit + cursor，页面间无重叠、无遗漏。
func TestReplyListRootPagination(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	now := time.Now()
	for i := 1; i <= 5; i++ {
		r := models.Reply{PostID: post.ID, AuthorID: 1, Content: fmt.Sprintf("r%d", i), Status: models.ReplyStatusNormal, CreatedAt: now.Add(-time.Duration(i) * time.Hour)}
		require.NoError(t, db.Create(&r).Error)
	}

	page1Rec := performReplyListRequest(t, db, post.ID, "sort=latest&limit=2", 0)
	require.Equal(t, http.StatusOK, page1Rec.Code)
	page1 := decodeReplyList(t, page1Rec.Body.Bytes())
	require.Len(t, page1.Replies, 2)
	require.Equal(t, "r1", page1.Replies[0].Content)
	require.Equal(t, "r2", page1.Replies[1].Content)
	require.NotEmpty(t, page1.NextCursor)
	require.EqualValues(t, 5, page1.Total)

	page2Rec := performReplyListRequest(t, db, post.ID, "sort=latest&limit=2&cursor="+page1.NextCursor, 0)
	require.Equal(t, http.StatusOK, page2Rec.Code)
	page2 := decodeReplyList(t, page2Rec.Body.Bytes())
	require.Len(t, page2.Replies, 2)
	require.Equal(t, "r3", page2.Replies[0].Content)
	require.Equal(t, "r4", page2.Replies[1].Content)
	require.NotEmpty(t, page2.NextCursor)

	page3Rec := performReplyListRequest(t, db, post.ID, "sort=latest&limit=2&cursor="+page2.NextCursor, 0)
	page3 := decodeReplyList(t, page3Rec.Body.Bytes())
	require.Len(t, page3.Replies, 1)
	require.Equal(t, "r5", page3.Replies[0].Content)
	require.Empty(t, page3.NextCursor)

	// 无重叠。
	seen := map[uint]bool{}
	for _, p := range []replyListResponse{page1, page2, page3} {
		for _, r := range p.Replies {
			require.False(t, seen[r.ID], "分页之间不得重复")
			seen[r.ID] = true
		}
	}
}

// TestReplyListCapsChildrenPerRoot 列表里每根最多携带 maxChildrenPerRoot 条子回复，
// 根上带真实 child_reply_count，剩余通过 children 接口懒加载。
func TestReplyListCapsChildrenPerRoot(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	now := time.Now()
	root := models.Reply{PostID: post.ID, AuthorID: 1, Content: "big-root", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-time.Hour)}
	require.NoError(t, db.Create(&root).Error)
	total := maxChildrenPerRoot + 10
	for i := 1; i <= total; i++ {
		ch := models.Reply{PostID: post.ID, ParentReplyID: &root.ID, AuthorID: 1, Content: fmt.Sprintf("ch%d", i), Status: models.ReplyStatusNormal, CreatedAt: now.Add(time.Duration(i) * time.Second)}
		require.NoError(t, db.Create(&ch).Error)
	}

	listRec := performReplyListRequest(t, db, post.ID, "sort=latest", 0)
	resp := decodeReplyList(t, listRec.Body.Bytes())
	require.Len(t, resp.Replies, 1+maxChildrenPerRoot, "根 + 最多 50 条子回复")
	require.Equal(t, total, resp.Replies[0].ChildReplyCount, "根应携带真实子回复总数")

	// children 接口第一页 50 条 + cursor 翻页取回剩余。
	c1Rec := performGetChildrenRequest(t, db, post.ID, root.ID, "limit=50", 0)
	var c1 struct {
		Replies    []models.Reply `json:"replies"`
		NextCursor string         `json:"next_cursor"`
	}
	require.NoError(t, json.Unmarshal(c1Rec.Body.Bytes(), &c1))
	require.Len(t, c1.Replies, 50)
	require.NotEmpty(t, c1.NextCursor)

	c2Rec := performGetChildrenRequest(t, db, post.ID, root.ID, "limit=50&cursor="+url.QueryEscape(c1.NextCursor), 0)
	var c2 struct {
		Replies    []models.Reply `json:"replies"`
		NextCursor string         `json:"next_cursor"`
	}
	require.NoError(t, json.Unmarshal(c2Rec.Body.Bytes(), &c2))
	require.Len(t, c2.Replies, 10)
	require.Empty(t, c2.NextCursor)
}

// TestReplyCreateNotifiesPreciseTarget 楼中楼里点击子回复 A 回复时，
// 通知必须发给 A 的作者，而不是根评论作者 B。
func TestReplyCreateNotifiesPreciseTarget(t *testing.T) {
	db := newReplyTestDB(t)
	createMessageTestUser(t, db, 1, "Alice") // 帖子作者
	createMessageTestUser(t, db, 2, "Bob")   // 根评论作者
	createMessageTestUser(t, db, 3, "Carol") // 子回复 A 作者
	createMessageTestUser(t, db, 4, "Dave")  // 楼中楼回复者 C
	now := time.Now()
	post := models.Post{
		Title: "通知目标测试帖", Content: "正文",
		BoardID: models.BoardShuitie, AuthorID: 1,
		ContentKind: models.PostContentKindNormal,
		Status: models.PostStatusNormal,
		CreatedAt: now, LastActivityAt: now,
	}
	require.NoError(t, db.Create(&post).Error)

	root := models.Reply{PostID: post.ID, AuthorID: 2, Content: "root", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-time.Hour)}
	require.NoError(t, db.Create(&root).Error)
	childA := models.Reply{PostID: post.ID, ParentReplyID: &root.ID, ReplyToUserID: &[]uint{2}[0], ReplyToReplyID: &root.ID, AuthorID: 3, Content: "A 回复 B", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-30 * time.Minute)}
	require.NoError(t, db.Create(&childA).Error)

	// C 点击 A 的"回复"：parent=root, reply_to_user_id=3, reply_to_reply_id=A。
	rec := performReplyCreateRequestAs(t, db, post.ID, 4, url.Values{
		"content":          {"@Carol 你好"},
		"parent_reply_id":  {fmt.Sprint(root.ID)},
		"reply_to_user_id": {fmt.Sprint(3)},
		"reply_to_reply_id": {fmt.Sprint(childA.ID)},
	})
	require.Equal(t, http.StatusCreated, rec.Code, "body=%s", rec.Body.String())

	var created models.Reply
	require.NoError(t, db.Where("author_id = ? AND content = ?", 4, "@Carol 你好").First(&created).Error)
	require.NotNil(t, created.ReplyToUserID)
	require.Equal(t, uint(3), *created.ReplyToUserID)
	require.NotNil(t, created.ReplyToReplyID)
	require.Equal(t, childA.ID, *created.ReplyToReplyID)

	// 通知目标是 3（Carol），不是 2（Bob）。
	var n models.Notification
	require.NoError(t, db.Where("type = ? AND related_id = ?", "reply", created.ID).First(&n).Error)
	require.Equal(t, uint(3), n.UserID, "通知必须发给精确回复目标")
}

// TestReplyCreateRejectsCrossThreadReplyTarget reply_to_reply_id 必须与 parent 同线程。
func TestReplyCreateRejectsCrossThreadReplyTarget(t *testing.T) {
	db := newReplyTestDB(t)
	createMessageTestUser(t, db, 2, "Bob")
	post := createReplyTestPost(t, db)
	now := time.Now()
	rootA := models.Reply{PostID: post.ID, AuthorID: 1, Content: "rootA", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-time.Hour)}
	rootB := models.Reply{PostID: post.ID, AuthorID: 2, Content: "rootB", Status: models.ReplyStatusNormal, CreatedAt: now.Add(-30 * time.Minute)}
	require.NoError(t, db.Create(&rootA).Error)
	require.NoError(t, db.Create(&rootB).Error)

	rec := performReplyCreateRequestAs(t, db, post.ID, 1, url.Values{
		"content":           {"跨线程"},
		"parent_reply_id":   {fmt.Sprint(rootA.ID)},
		"reply_to_reply_id": {fmt.Sprint(rootB.ID)},
	})
	require.Equal(t, http.StatusBadRequest, rec.Code)
	require.Contains(t, rec.Body.String(), "不属于该评论线程")
}

// TestReplyCreateRejectsReplyToReplyWithoutParent reply_to_reply_id 必须有父评论。
func TestReplyCreateRejectsReplyToReplyWithoutParent(t *testing.T) {
	db := newReplyTestDB(t)
	post := createReplyTestPost(t, db)
	rec := performReplyCreateRequestAs(t, db, post.ID, 1, url.Values{
		"content":           {"无父评论"},
		"reply_to_reply_id": {"99"},
	})
	require.Equal(t, http.StatusBadRequest, rec.Code)
	require.Contains(t, rec.Body.String(), "精确回复目标需要父评论")
}
