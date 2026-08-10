package services

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var visibilityTestDBSeq int64

// newVisibilityTestDB 每个用例使用独立内存库，避免共享 cache=shared 状态串扰。
func newVisibilityTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&visibilityTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:visibility_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.FeedFeedback{}, &models.UserHiddenAuthor{}, &models.Post{}))
	return db
}

func createTestPosts(t *testing.T, db *gorm.DB, authorID uint, count int) []models.Post {
	t.Helper()
	posts := make([]models.Post, 0, count)
	for i := 0; i < count; i++ {
		p := models.Post{
			BoardID:  models.BoardShuitie,
			AuthorID: authorID,
			Title:    "帖",
			Content:  "内容",
			Status:   models.PostStatusNormal,
		}
		require.NoError(t, db.Create(&p).Error)
		posts = append(posts, p)
	}
	return posts
}

func TestMarkNotInterestedSets90DayExpiry(t *testing.T) {
	db := newVisibilityTestDB(t)
	svc := NewFeedVisibilityService(db)

	now := time.Now()
	require.NoError(t, svc.MarkNotInterested(1, 100, "all"))

	var fb models.FeedFeedback
	require.NoError(t, db.First(&fb, "user_id = ? AND post_id = ?", uint(1), uint(100)).Error)
	require.NotNil(t, fb.ExpiresAt)
	// ~90 天（±1 分钟容差）。
	require.WithinDuration(t, now.Add(90*24*time.Hour), *fb.ExpiresAt, time.Minute)
}

func TestMarkNotInterestedRepeatRefreshesExpiryAndSource(t *testing.T) {
	db := newVisibilityTestDB(t)
	svc := NewFeedVisibilityService(db)

	require.NoError(t, svc.MarkNotInterested(1, 100, "time"))
	time.Sleep(5 * time.Millisecond)

	// 用户再次表达负反馈：Source 更新，有效期重新起算。
	require.NoError(t, svc.MarkNotInterested(1, 100, "following"))

	var fb models.FeedFeedback
	require.NoError(t, db.First(&fb, "user_id = ? AND post_id = ?", uint(1), uint(100)).Error)
	require.Equal(t, "following", fb.Source)
	require.WithinDuration(t, time.Now().Add(90*24*time.Hour), *fb.ExpiresAt, time.Minute)
}

func TestGetNotInterestedPostIDsFiltersExpired(t *testing.T) {
	db := newVisibilityTestDB(t)
	svc := NewFeedVisibilityService(db)
	now := time.Now()

	// 有效（未过期）。
	require.NoError(t, svc.MarkNotInterested(1, 100, "all"))
	// 过期：直接落库一条 expired_at 已到期的记录。
	expired := now.Add(-time.Hour)
	require.NoError(t, db.Create(&models.FeedFeedback{
		UserID: 1, PostID: 101, Action: models.FeedFeedbackActionNotInterested,
		Source: "all", CreatedAt: expired, ExpiresAt: &expired,
	}).Error)
	// 历史 NULL 兼容：仍视为有效。
	require.NoError(t, db.Create(&models.FeedFeedback{
		UserID: 1, PostID: 102, Action: models.FeedFeedbackActionNotInterested, Source: "all",
	}).Error)

	ids, err := svc.GetNotInterestedPostIDs(1, now)
	require.NoError(t, err)
	require.ElementsMatch(t, []uint{100, 102}, ids, "过期记录不应返回，NULL 记录仍有效")
}

func TestApplyFeedVisibilityRespectsExpiry(t *testing.T) {
	db := newVisibilityTestDB(t)
	svc := NewFeedVisibilityService(db)
	now := time.Now()

	posts := createTestPosts(t, db, 50, 3)
	// p1 有过期反馈（不过滤），p2 有有效反馈（过滤）。
	expired := now.Add(-time.Hour)
	require.NoError(t, db.Create(&models.FeedFeedback{
		UserID: 1, PostID: posts[0].ID, Action: models.FeedFeedbackActionNotInterested,
		Source: "all", CreatedAt: expired, ExpiresAt: &expired,
	}).Error)
	require.NoError(t, svc.MarkNotInterested(1, posts[1].ID, "all"))

	// all Tab：p2 被过滤，p1（过期）与 p3 保留。
	query := svc.ApplyFeedVisibility(db.Model(&models.Post{}).Where("author_id = ?", uint(50)), 1, "all", now)
	var visible []models.Post
	require.NoError(t, query.Find(&visible).Error)
	var visibleIDs []uint
	for _, p := range visible {
		visibleIDs = append(visibleIDs, p.ID)
	}
	require.ElementsMatch(t, []uint{posts[0].ID, posts[2].ID}, visibleIDs)

	// time Tab：not_interested 不生效，三条都在。
	queryTime := svc.ApplyFeedVisibility(db.Model(&models.Post{}).Where("author_id = ?", uint(50)), 1, "time", now)
	var visibleTime []models.Post
	require.NoError(t, queryTime.Find(&visibleTime).Error)
	require.Len(t, visibleTime, 3)
}

func TestApplyFeedVisibilityHiddenAuthorAllKinds(t *testing.T) {
	db := newVisibilityTestDB(t)
	svc := NewFeedVisibilityService(db)
	now := time.Now()

	createTestPosts(t, db, 60, 2)
	require.NoError(t, svc.HideAuthor(1, 60))

	for _, kind := range []string{"all", "time", "featured", "following"} {
		query := svc.ApplyFeedVisibility(db.Model(&models.Post{}).Where("author_id = ?", uint(60)), 1, kind, now)
		var visible []models.Post
		require.NoError(t, query.Find(&visible).Error)
		require.Empty(t, visible, "隐藏作者对所有 Tab 生效: %s", kind)
	}
}

func TestCleanupExpiredFeedbacks(t *testing.T) {
	db := newVisibilityTestDB(t)
	svc := NewFeedVisibilityService(db)
	now := time.Now()

	expired := now.Add(-time.Hour)
	// 过期。
	require.NoError(t, db.Create(&models.FeedFeedback{
		UserID: 1, PostID: 1, Action: models.FeedFeedbackActionNotInterested, Source: "all",
		CreatedAt: expired, ExpiresAt: &expired,
	}).Error)
	// 未过期。
	require.NoError(t, svc.MarkNotInterested(1, 2, "all"))
	// NULL（永久有效，不清）。
	require.NoError(t, db.Create(&models.FeedFeedback{
		UserID: 1, PostID: 3, Action: models.FeedFeedbackActionNotInterested, Source: "all",
	}).Error)

	removed, err := svc.CleanupExpiredFeedbacks(context.Background(), now)
	require.NoError(t, err)
	require.EqualValues(t, 1, removed)

	var count int64
	require.NoError(t, db.Model(&models.FeedFeedback{}).Count(&count).Error)
	require.EqualValues(t, 2, count)
}
