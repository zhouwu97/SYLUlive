package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var postVisibilityTestDBSeq int64

// newPostFeedTestDB 建立公共 Feed 回归所需的最小表集合。
func newPostFeedTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&postVisibilityTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:postvis_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{}, &models.Post{}, &models.PostImage{}, &models.File{}, &models.ImageVariant{},
		&models.Like{}, &models.WaterTeamRecruitment{}, &models.WaterTeamApplication{},
	))
	return db
}

func seedFeedAuthor(t *testing.T, db *gorm.DB) models.User {
	t.Helper()
	user := models.User{StudentID: fmt.Sprintf("seed-%d", atomic.AddInt64(&postVisibilityTestDBSeq, 1)), PasswordHash: "x", Nickname: "作者"}
	require.NoError(t, db.Create(&user).Error)
	return user
}

func seedFeedPost(t *testing.T, db *gorm.DB, author models.User, board models.BoardID, status models.PostStatus, title string) models.Post {
	t.Helper()
	post := models.Post{
		Title: title, Content: "正文-" + title, BoardID: board, AuthorID: author.ID,
		Status: status, CreatedAt: time.Now(), LastActivityAt: time.Now(),
	}
	require.NoError(t, db.Create(&post).Error)
	return post
}

// getListRequest 以真实 handler 入口发起一次列表请求。
func getListRequest(t *testing.T, h *PostHandler, userID uint, query string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/posts?"+query, nil)
	if userID != 0 {
		c.Set("user_id", userID)
	}
	h.GetList(c)
	return w
}

type feedListBody struct {
	Posts      []models.Post `json:"posts"`
	Total      int           `json:"total"`
	NextOffset int           `json:"next_offset"`
	HasMore    bool          `json:"has_more"`
	SessionID  string        `json:"session_id"`
	Code       string        `json:"code"`
}

func decodeFeedList(t *testing.T, w *httptest.ResponseRecorder) feedListBody {
	t.Helper()
	var body feedListBody
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
	return body
}

// VIS-01/VIS-02：快照生成后被治理隐藏、作者删除或标记已售的帖子，下一次公共读取不得再返回。
func TestSnapshotReplayExcludesHiddenAndDeletedPosts(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)

	// 集市 board=2 + sort=all 会生成通用快照。
	var posts []models.Post
	for i := 0; i < 12; i++ {
		posts = append(posts, seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, fmt.Sprintf("market-%02d", i)))
	}

	first := getListRequest(t, h, 0, "board=2&sort=all&limit=10")
	require.Equal(t, http.StatusOK, first.Code, first.Body.String())
	body := decodeFeedList(t, first)
	require.Len(t, body.Posts, 10)
	require.NotEmpty(t, body.SessionID)
	require.True(t, body.HasMore)
	require.Equal(t, 10, body.NextOffset)

	// 快照建立后再隐藏第 3 条、删除第 5 条、标记第 7 条已售（只改状态，记录仍存在）。
	hiddenID := posts[2].ID
	deletedID := posts[4].ID
	soldID := posts[6].ID
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", hiddenID).Update("status", models.PostStatusModeratedHidden).Error)
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", deletedID).Update("status", models.PostStatusDeleted).Error)
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", soldID).Update("status", models.PostStatusSold).Error)

	second := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=0&limit=10&capabilities=%s", body.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusOK, second.Code, second.Body.String())
	secondBody := decodeFeedList(t, second)
	for _, post := range secondBody.Posts {
		require.NotEqual(t, hiddenID, post.ID, "治理隐藏的帖子不得从快照回读返回")
		require.NotEqual(t, deletedID, post.ID, "已删除的帖子不得从快照回读返回")
		require.NotEqual(t, soldID, post.ID, "已售商品不得从集市快照回读返回")
	}
	// 不能只靠前端隐藏：正文本身也不能出现在响应里。
	raw := second.Body.String()
	require.NotContains(t, raw, posts[2].Content)
	require.NotContains(t, raw, posts[4].Content)
	require.NotContains(t, raw, posts[6].Content)
	// 短页但必须按原始候选位置推进。
	require.Equal(t, 7, len(secondBody.Posts))
	require.Equal(t, 10, secondBody.NextOffset)
}

// VIS-03：集市合法的历史公开状态（已售出/已关闭）必须保留，只剔除非公开状态。
func TestPublicReadKeepsSoldAndClosedButDropsUnknownStatus(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)

	normal := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, "在售")
	sold := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusSold, "已售出")
	closed := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusClosed, "已关闭")
	hidden := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusModeratedHidden, "已隐藏")
	unknown := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatus("future_status"), "未来状态")

	ids := []uint{normal.ID, sold.ID, closed.ID, hidden.ID, unknown.ID}
	visible, err := h.loadPostsInOrder(ids, publicPostStatuses)
	require.NoError(t, err)

	got := map[uint]bool{}
	for _, post := range visible {
		got[post.ID] = true
	}
	require.True(t, got[normal.ID])
	require.True(t, got[sold.ID], "sold 属于公共可见状态")
	require.True(t, got[closed.ID], "closed 属于公共可见状态")
	require.False(t, got[hidden.ID], "治理隐藏不在公共白名单")
	require.False(t, got[unknown.ID], "未知状态必须默认不公开，不能用排除法放行")

	// 缺失记录不得生成零值帖子。
	missing, err := h.loadPostsInOrder([]uint{999999}, publicPostStatuses)
	require.NoError(t, err)
	require.Empty(t, missing)

	// 空 ID 列表必须返回空切片而不是 nil 报错。
	empty, err := h.loadPostsInOrder(nil, publicPostStatuses)
	require.NoError(t, err)
	require.Empty(t, empty)
}

// 集市公共列表只展示仍在进行中的出售内容和其他未售完的集市状态；已售商品
// 仍由详情与个人记录接口保留，不应继续占用公共列表的位置。
func TestMarketListExcludesSoldPosts(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)

	normal := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, "在售商品")
	sold := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusSold, "已售商品")
	closed := seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusClosed, "已结束求购")

	for _, query := range []string{"board=2&sort=time&limit=20", "board=2&sort=all&limit=20"} {
		response := getListRequest(t, h, 0, query)
		require.Equal(t, http.StatusOK, response.Code, "query=%s body=%s", query, response.Body.String())
		body := decodeFeedList(t, response)
		ids := make(map[uint]bool, len(body.Posts))
		for _, post := range body.Posts {
			ids[post.ID] = true
		}
		require.True(t, ids[normal.ID], "query=%s should keep normal post", query)
		require.True(t, ids[closed.ID], "query=%s should keep closed non-sale post", query)
		require.False(t, ids[sold.ID], "query=%s must exclude sold post", query)
		require.NotContains(t, response.Body.String(), "已售商品")
	}
}

// VIS-04/PAGE-07：同一份快照不能跨用户、跨筛选参数复用。
func TestSnapshotRejectedWhenUserOrFilterChanges(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)
	for i := 0; i < 6; i++ {
		seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, fmt.Sprintf("m-%d", i))
	}

	first := getListRequest(t, h, 0, "board=2&sort=all&limit=5")
	require.Equal(t, http.StatusOK, first.Code)
	body := decodeFeedList(t, first)
	require.NotEmpty(t, body.SessionID)

	// 换排序参数 → 不能复用旧 ID 列表。
	changedSort := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=hot&scene=loadmore&session_id=%s&offset=0&limit=5&capabilities=%s", body.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusConflict, changedSort.Code, "换排序不得复用旧快照")
	require.Equal(t, "feed_session_expired", decodeFeedList(t, changedSort).Code)
	require.NotContains(t, changedSort.Body.String(), "正文-m-0")

	// 换用户 → 不能复用他人快照。
	second := getListRequest(t, h, 0, "board=2&sort=all&limit=5")
	require.Equal(t, http.StatusOK, second.Code)
	body2 := decodeFeedList(t, second)
	require.NotEmpty(t, body2.SessionID)

	otherUser := seedFeedAuthor(t, db)
	crossUser := getListRequest(t, h, otherUser.ID, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=0&limit=5&capabilities=%s", body2.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusConflict, crossUser.Code, "跨用户不得复用快照")
	require.Equal(t, "feed_session_expired", decodeFeedList(t, crossUser).Code)
}

// PAGE-01/PAGE-02：非法分页参数返回 400，真实 Gin 路由不 panic。
func TestFeedPaginationRejectsInvalidParams(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")

	cases := []struct {
		name  string
		query string
	}{
		{"offset 负数", "board=2&sort=all&offset=-1"},
		{"offset 非数字", "board=2&sort=all&offset=abc"},
		{"offset 超大整数", "board=2&sort=all&offset=99999999999999999999"},
		{"page 为 0", "board=2&sort=all&page=0"},
		{"page 负数", "board=2&sort=all&page=-2"},
		{"page 非数字", "board=2&sort=all&page=x"},
		{"limit 为 0", "board=2&sort=all&limit=0"},
		{"limit 负数", "board=2&sort=all&limit=-5"},
		{"limit 非数字", "board=2&sort=all&limit=abc"},
		{"page 极大导致偏移溢出", "board=2&sort=all&page=9223372036854775807&limit=50"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := getListRequest(t, h, 0, tc.query)
			require.Equal(t, http.StatusBadRequest, w.Code, "query=%s body=%s", tc.query, w.Body.String())
			require.Equal(t, "invalid_pagination", decodeFeedList(t, w).Code)
		})
	}

	// limit 超过上限按上限截断而不是报错：保持对旧客户端传大值的容忍。
	author := seedFeedAuthor(t, db)
	seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, "only")
	clamped := getListRequest(t, h, 0, "board=2&sort=all&limit=99999")
	require.Equal(t, http.StatusOK, clamped.Code, clamped.Body.String())
	require.Len(t, decodeFeedList(t, clamped).Posts, 1)
}

// PAGE-02：非负且超过结果尾部的合法 offset 返回空列表与 has_more=false，不 panic 不无限重试。
func TestFeedPaginationBeyondTailReturnsEmptyPage(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)
	for i := 0; i < 3; i++ {
		seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, fmt.Sprintf("tail-%d", i))
	}

	first := getListRequest(t, h, 0, "board=2&sort=all&limit=20")
	require.Equal(t, http.StatusOK, first.Code)
	body := decodeFeedList(t, first)
	require.Len(t, body.Posts, 3)
	require.False(t, body.HasMore, "候选已全部扫描完")
	require.Equal(t, 3, body.NextOffset)

	beyond := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=50&limit=20&capabilities=%s", body.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusOK, beyond.Code, beyond.Body.String())
	beyondBody := decodeFeedList(t, beyond)
	require.Empty(t, beyondBody.Posts)
	require.False(t, beyondBody.HasMore)
	require.Equal(t, 3, beyondBody.NextOffset)
}

// PAGE-03/PAGE-04：过滤后的短页按原始候选位置推进，不重复、不提前结束，空可见窗口也能继续。
func TestFilteredFeedAdvancesByRawOffset(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)

	for i := 0; i < 30; i++ {
		seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, fmt.Sprintf("adv-%02d", i))
	}

	// 先取一次完整列表，拿到服务端真实的候选顺序（综合排序不是按创建时间），
	// 后续按该顺序构造“第一页短页 / 第二页整页不可见”。
	baseline := getListRequest(t, h, 0, "board=2&sort=all&limit=50")
	require.Equal(t, http.StatusOK, baseline.Code)
	baselineBody := decodeFeedList(t, baseline)
	require.Len(t, baselineBody.Posts, 30)
	order := make([]uint, 0, len(baselineBody.Posts))
	for _, post := range baselineBody.Posts {
		order = append(order, post.ID)
	}

	// 快照已经保存了 30 个候选 ID；此后让第二页窗口 (10..19) 整页不可见，
	// 第一页窗口 (0..9) 剔除 5 条，模拟真实“边翻页边被删除/隐藏”的时序。
	for _, id := range order[10:20] {
		require.NoError(t, db.Model(&models.Post{}).Where("id = ?", id).Update("status", models.PostStatusDeleted).Error)
	}
	for _, id := range order[0:5] {
		require.NoError(t, db.Model(&models.Post{}).Where("id = ?", id).Update("status", models.PostStatusModeratedHidden).Error)
	}

	refreshBody := baselineBody
	// 第一页：候选窗口 0..9，其中 5 条已不可见 → 允许短页，但 next_offset 必须按原始窗口推进。
	page1 := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=0&limit=10&capabilities=%s", refreshBody.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusOK, page1.Code, page1.Body.String())
	page1Body := decodeFeedList(t, page1)
	require.Len(t, page1Body.Posts, 5, "短页允许，但不得跨窗口补满")
	require.Equal(t, 10, page1Body.NextOffset, "next_offset 是原始候选消费位置，不是已显示条数")
	require.True(t, page1Body.HasMore)

	// 第二页：整窗口不可见 → 空页，但必须继续推进而不是永久结束。
	page2 := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=10&limit=10&capabilities=%s", refreshBody.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusOK, page2.Code, page2.Body.String())
	page2Body := decodeFeedList(t, page2)
	require.Empty(t, page2Body.Posts)
	require.Equal(t, 20, page2Body.NextOffset)
	require.True(t, page2Body.HasMore, "后面仍有未扫描候选，不能因为空可见页就结束列表")

	// 第三页必须能取到后续公开数据，且不重复前两页内容。
	page3 := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=20&limit=10&capabilities=%s", refreshBody.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusOK, page3.Code, page3.Body.String())
	page3Body := decodeFeedList(t, page3)
	require.Len(t, page3Body.Posts, 10)
	seen := map[uint]bool{}
	for _, post := range page1Body.Posts {
		seen[post.ID] = true
	}
	for _, post := range page2Body.Posts {
		seen[post.ID] = true
	}
	for _, post := range page3Body.Posts {
		require.False(t, seen[post.ID], "翻页不得重复返回同一帖子")
	}
	require.Equal(t, 30, page3Body.NextOffset)
	require.False(t, page3Body.HasMore)
}

// PAGE-06：旧客户端无法识别分页元数据时，安全优先，返回 409 要求刷新，不返回受限内容。
func TestLegacyClientGetsConflictInsteadOfRestrictedContent(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	author := seedFeedAuthor(t, db)

	var posts []models.Post
	for i := 0; i < 10; i++ {
		posts = append(posts, seedFeedPost(t, db, author, models.BoardMarket, models.PostStatusNormal, fmt.Sprintf("legacy-%d", i)))
	}

	first := getListRequest(t, h, 0, "board=2&sort=all&limit=5")
	require.Equal(t, http.StatusOK, first.Code)
	body := decodeFeedList(t, first)
	require.NotEmpty(t, body.SessionID)

	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", posts[0].ID).Update("status", models.PostStatusDeleted).Error)
	require.NoError(t, db.Model(&models.Post{}).Where("id = ?", posts[1].ID).Update("status", models.PostStatusModeratedHidden).Error)

	// 不带能力声明：过滤后的短页必须走 409，而不是把隐藏内容塞回去。
	legacy := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=0&limit=5", body.SessionID))
	require.Equal(t, http.StatusConflict, legacy.Code, legacy.Body.String())
	require.Equal(t, "feed_session_expired", decodeFeedList(t, legacy).Code)
	require.NotContains(t, legacy.Body.String(), posts[0].Content)
	require.NotContains(t, legacy.Body.String(), posts[1].Content)

	// 声明能力的客户端得到正常短页 + 推进元数据。
	modern := getListRequest(t, h, 0, fmt.Sprintf("board=2&sort=all&scene=loadmore&session_id=%s&offset=0&limit=5&capabilities=%s", body.SessionID, paginationMetaCapability))
	require.Equal(t, http.StatusOK, modern.Code, modern.Body.String())
	modernBody := decodeFeedList(t, modern)
	require.Len(t, modernBody.Posts, 3)
	require.Equal(t, 5, modernBody.NextOffset)
}

// FIX-06：创建帖子失败时不得把内部错误拼进响应体。
func TestPostCreateInternalErrorIsRedacted(t *testing.T) {
	db := newPostFeedTestDB(t)
	h := NewPostHandler(db, "", "")
	user := seedFeedAuthor(t, db)

	// 注入一个含模拟 DSN / 路径 / 令牌字样的内部错误。
	require.NoError(t, db.Callback().Create().Before("gorm:create").Register("inject_post_create_error", func(tx *gorm.DB) {
		if tx.Statement != nil && tx.Statement.Schema != nil && tx.Statement.Schema.Name == "Post" {
			tx.AddError(errors.New("pq: dial tcp 10.11.12.13:5432: connect: connection refused dsn=postgres://sylu:SUPER_SECRET_TOKEN@db.internal/shenliyuan"))
		}
	}))

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	// board_id=3（占位版块）不触发集市发布资格校验，确保失败来自帖子创建事务本身。
	form := "title=hello&content=world&board_id=3"
	c.Request = httptest.NewRequest(http.MethodPost, "/api/posts", strings.NewReader(form))
	c.Request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	c.Set("user_id", user.ID)
	c.Set("role", "user")
	h.Create(c)

	require.Equal(t, http.StatusInternalServerError, w.Code, w.Body.String())
	raw := w.Body.String()
	for _, leaked := range []string{"SUPER_SECRET_TOKEN", "postgres://", "10.11.12.13", "pq: dial tcp", "gorm"} {
		require.NotContains(t, raw, leaked, "内部错误细节不得出现在响应体：%s", leaked)
	}

	var body map[string]interface{}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
	require.Equal(t, "post_create_failed", body["code"])
	require.Equal(t, "创建帖子失败，请稍后重试", body["error"])
	// 仍要能通过 request_id 定位问题。
	require.NotEmpty(t, body["request_id"])
}
