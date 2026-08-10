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
	require.NoError(t, db.AutoMigrate(&models.Post{}, &models.User{}, &models.FeedFeedback{}, &models.UserHiddenAuthor{}))
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

	// 用户 1 创建综合快照。
	storeSnapshot("sessA", Snapshot{
		UserID: 1, PostIDs: []uint{99}, ExpiredAt: now.Add(10 * time.Minute),
		AlgorithmVersion: "home_all_v2", Sort: "all", FeedKind: "home_v2",
	})

	// 用户 1 loadmore → 通过归属校验。
	cA, wA := feedCtx(1, nil)
	h.getHomeFeedV2(cA, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusOK, wA.Code, "同用户 loadmore 应成功")

	// 用户 2 loadmore → 409，不得复用他人个性化快照。
	cB, wB := feedCtx(2, nil)
	h.getHomeFeedV2(cB, "all", "loadmore", "sessA", 1, 20, 0, now, false)
	require.Equal(t, http.StatusConflict, wB.Code, "跨用户 loadmore 应 409")

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

	storeSnapshot("sessA", Snapshot{
		UserID: hider.ID, PostIDs: []uint{99}, ExpiredAt: now.Add(10 * time.Minute),
		AlgorithmVersion: "home_all_v2", Sort: "all", FeedKind: "home_v2",
	})

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

	storeSnapshot("sessA", Snapshot{
		UserID: me.ID, PostIDs: []uint{99}, ExpiredAt: now.Add(10 * time.Minute),
		AlgorithmVersion: "home_all_v2", Sort: "all", FeedKind: "home_v2",
	})

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

func TestSnapshotUserIndexLifecycle(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	_ = db

	storeSnapshot("s1", Snapshot{UserID: 7, PostIDs: []uint{1}, ExpiredAt: time.Now().Add(time.Minute)})
	storeSnapshot("s2", Snapshot{UserID: 7, PostIDs: []uint{2}, ExpiredAt: time.Now().Add(time.Minute)})
	storeSnapshot("s3", Snapshot{UserID: 0, PostIDs: []uint{3}, ExpiredAt: time.Now().Add(time.Minute)})

	_, ok := ActiveSnapshots.Load("s1")
	require.True(t, ok)
	_, ok = ActiveSnapshots.Load("s3")
	require.True(t, ok)

	// 单条删除：s2 从快照与索引中移除。
	deleteSnapshot("s2")
	_, ok = ActiveSnapshots.Load("s2")
	require.False(t, ok)

	// 全量失效用户 7：s1 删除，generic s3 保留。
	invalidateUserFeedSnapshots(7)
	_, ok = ActiveSnapshots.Load("s1")
	require.False(t, ok)
	_, ok = ActiveSnapshots.Load("s3")
	require.True(t, ok, "匿名/generic 快照不应被用户失效误伤")
}
