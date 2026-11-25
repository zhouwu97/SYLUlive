package handlers

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var feedSnapshotTestDBSeq int64

func newFeedSnapshotTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&feedSnapshotTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:snapshot_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	// 回归目标包含“真实存在的公开帖子”这一情形，因此需要帖子图片相关表，
	// 否则 loadPostsInOrder 的 Preload("Images") 会因缺表而直接失败。
	require.NoError(t, db.AutoMigrate(&models.FeedSnapshot{},
		&models.Post{}, &models.User{}, &models.FeedFeedback{}, &models.UserHiddenAuthor{},
		&models.PostImage{}, &models.File{}, &models.ImageVariant{},
	))
	return db
}

func feedCtx(userID uint, params gin.Params) (*gin.Context, *httptest.ResponseRecorder) {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", userID)
	c.Params = params
	c.Request = httptest.NewRequest(http.MethodGet, "/api/posts", nil)
	return c, w
}

func TestHomeFeedV2SnapshotUserIDBinding(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	h := NewPostHandler(db, "", "")
	now := time.Now()

	// 快照里必须是真实存在的公开帖子：本用例只验证归属校验，
	// 悬空 ID 会命中“可见性过滤后短页”的分支而返回 409，不属于本用例关注点。
	author := models.User{Nickname: "作者", PasswordHash: "x"}
	require.NoError(t, db.Create(&author).Error)
	snapPost := models.Post{
		BoardID: models.BoardShuitie, AuthorID: author.ID,
		Title: "快照帖", Content: "x", Status: models.PostStatusNormal,
	}
	require.NoError(t, db.Create(&snapPost).Error)

	// 用户 1 创建综合快照。
	require.NoError(t, db.Create(&models.FeedSnapshot{SessionID: "sessA",
		UserID: 1, PostIDs: []uint{snapPost.ID}, ExpiredAt: now.Add(10 * time.Minute),
		AlgorithmVersion: "home_all_v2", Sort: "all", FeedKind: "home_v2",
	}).Error)

	// 用户 1 loadmore → 通过归属校验。
	cA, wA := feedCtx(1, nil)
	h.getHomeFeedV2(cA, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusOK, wA.Code, "同用户 loadmore 应成功")

	// 用户 2 loadmore → 409，不得复用他人个性化快照。
	cB, wB := feedCtx(2, nil)
	h.getHomeFeedV2(cB, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusConflict, wB.Code, "跨用户 loadmore 应 409")

	// 不匹配的请求不能删除归属人的快照。
	cAgain, wAgain := feedCtx(1, nil)
	h.getHomeFeedV2(cAgain, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusOK, wAgain.Code)

	// 匿名（userID=0）loadmore 用户 1 的快照 → 409。
	cC, wC := feedCtx(0, nil)
	h.getHomeFeedV2(cC, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusConflict, wC.Code, "匿名不得复用登录用户快照")
}

func TestHomeFeedV2SnapshotInvalidatedByFeedback(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	h := NewPostHandler(db, "", "")
	feedH := NewFeedHandler(db)
	now := time.Now()

	hider := models.User{Nickname: "隐藏者", PasswordHash: "x"}
	target := models.User{Nickname: "被隐藏", PasswordHash: "x"}
	require.NoError(t, db.Create(&hider).Error)
	require.NoError(t, db.Create(&target).Error)

	require.NoError(t, db.Create(&models.FeedSnapshot{SessionID: "sessA",
		UserID: hider.ID, PostIDs: []uint{99}, ExpiredAt: now.Add(10 * time.Minute),
		AlgorithmVersion: "home_all_v2", Sort: "all", FeedKind: "home_v2",
	}).Error)

	// 隐藏者隐藏目标作者 → 触发快照失效。
	cHide, wHide := feedCtx(hider.ID, gin.Params{{Key: "author_id", Value: fmt.Sprintf("%d", target.ID)}})
	feedH.HideAuthor(cHide)
	require.Equal(t, http.StatusOK, wHide.Code)

	// 快照已被失效：隐藏者再 loadmore → 409。
	cLoad, wLoad := feedCtx(hider.ID, nil)
	h.getHomeFeedV2(cLoad, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusConflict, wLoad.Code, "隐藏作者后旧综合快照应失效")
}

func TestHomeFeedV2SnapshotInvalidatedByNotInterested(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	h := NewPostHandler(db, "", "")
	feedH := NewFeedHandler(db)
	now := time.Now()

	me := models.User{Nickname: "我", PasswordHash: "x"}
	other := models.User{Nickname: "别人", PasswordHash: "x"}
	require.NoError(t, db.Create(&me).Error)
	require.NoError(t, db.Create(&other).Error)
	otherPost := models.Post{BoardID: models.BoardShuitie, AuthorID: other.ID, Title: "别人帖", Content: "x", Status: models.PostStatusNormal}
	require.NoError(t, db.Create(&otherPost).Error)

	require.NoError(t, db.Create(&models.FeedSnapshot{SessionID: "sessA",
		UserID: me.ID, PostIDs: []uint{99}, ExpiredAt: now.Add(10 * time.Minute),
		AlgorithmVersion: "home_all_v2", Sort: "all", FeedKind: "home_v2",
	}).Error)

	cMark, wMark := feedCtx(me.ID, gin.Params{{Key: "post_id", Value: fmt.Sprintf("%d", otherPost.ID)}})
	feedH.MarkNotInterested(cMark)
	require.Equal(t, http.StatusOK, wMark.Code)

	cLoad, wLoad := feedCtx(me.ID, nil)
	h.getHomeFeedV2(cLoad, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusConflict, wLoad.Code, "标记不感兴趣后旧综合快照应失效")
}

func TestFeedSelfFeedbackGuards(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	feedH := NewFeedHandler(db)

	me := models.User{Nickname: "自己", PasswordHash: "x"}
	require.NoError(t, db.Create(&me).Error)
	myPost := models.Post{BoardID: models.BoardShuitie, AuthorID: me.ID, Title: "我的帖", Content: "x", Status: models.PostStatusNormal}
	require.NoError(t, db.Create(&myPost).Error)

	// 隐藏自己 → 400。
	cHide, wHide := feedCtx(me.ID, gin.Params{{Key: "author_id", Value: fmt.Sprintf("%d", me.ID)}})
	feedH.HideAuthor(cHide)
	require.Equal(t, http.StatusBadRequest, wHide.Code, "不能隐藏自己")

	// 对自己的帖子不感兴趣 → 400。
	cMark, wMark := feedCtx(me.ID, gin.Params{{Key: "post_id", Value: fmt.Sprintf("%d", myPost.ID)}})
	feedH.MarkNotInterested(cMark)
	require.Equal(t, http.StatusBadRequest, wMark.Code, "不能对自己的帖子标记不感兴趣")

	// 不落库任何反馈。
	var fbCount int64
	require.NoError(t, db.Model(&models.FeedFeedback{}).Count(&fbCount).Error)
	require.Zero(t, fbCount, "自反馈不应写入 FeedFeedback")
}

func TestFeedSnapshotInvalidationDuringBuild(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	post := NewPostHandler(db, "", "")
	feed := NewFeedHandler(db)
	c, w := feedCtx(7, nil)
	pending := post.beginSnapshot(c, models.FeedSnapshot{FeedKind: "home_v2"})
	require.NotNil(t, pending)
	restore, resp := feedCtx(7, gin.Params{{Key: "author_id", Value: "8"}})
	feed.RestoreAuthor(restore)
	require.Equal(t, 200, resp.Code)
	require.False(t, post.finishSnapshot(c, pending, []uint{1, 2}))
	require.Equal(t, 409, w.Code)
}

func TestHomeSnapshotAcrossInstances(t *testing.T) {
	dbA := newFeedSnapshotTestDB(t)
	dbB, err := gorm.Open(dbA.Dialector, &gorm.Config{})
	require.NoError(t, err)
	pool, err := dbB.DB()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, pool.Close()) })
	testHomeSnapshotPages(t, dbA, dbB)
}

func testHomeSnapshotPages(t *testing.T, a, b *gorm.DB) {
	require.NoError(t, a.AutoMigrate(&models.FeedSnapshot{}, &models.User{}, &models.Post{}, &models.PostImage{}, &models.File{}, &models.ImageVariant{}, &models.WaterTeamRecruitment{}, &models.Reply{}, &models.FeedFeedback{}, &models.UserHiddenAuthor{}, &models.Like{}, &models.Topic{}, &models.PostTopic{}))
	author := seedFeedAuthor(t, a)
	for _, title := range []string{"第一页", "第二页"} {
		seedFeedPost(t, a, author, models.BoardShuitie, models.PostStatusNormal, title)
	}
	const query = "board=1&sort=all&feed_version=2&limit=1"
	first := getListRequest(t, NewPostHandler(a, "", ""), author.ID, query)
	require.Equal(t, 200, first.Code, first.Body.String())
	page := decodeFeedList(t, first)
	require.NotEmpty(t, page.SessionID)
	require.Len(t, page.Posts, 1)
	next := query + "&scene=loadmore&offset=1&session_id=" + page.SessionID
	h := NewPostHandler(b, "", "")
	require.Equal(t, 409, getListRequest(t, h, 0, next).Code)
	second := getListRequest(t, h, author.ID, next)
	require.Equal(t, 200, second.Code, second.Body.String())
	more := decodeFeedList(t, second)
	require.Len(t, more.Posts, 1)
	require.NotEqual(t, page.Posts[0].ID, more.Posts[0].ID)
	require.Equal(t, page.SessionID, more.SessionID)
	require.NoError(t, a.Model(&models.FeedSnapshot{}).Where("session_id = ?", page.SessionID).Update("expired_at", time.Now().UTC().Add(-time.Minute)).Error)
	expired := getListRequest(t, h, author.ID, next)
	require.Equal(t, 409, expired.Code)
	require.Equal(t, "feed_session_expired", decodeFeedList(t, expired).Code)
}
