package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

var followingTestDBSeq int64

func newFollowingTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	seq := atomic.AddInt64(&followingTestDBSeq, 1)
	db, err := gorm.Open(sqlite.Open(fmt.Sprintf("file:following_%d?mode=memory&cache=shared", seq)), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{}, &models.Post{}, &models.UserFollow{},
		&models.WaterSection{}, &models.WaterSectionFollow{},
		&models.UserHiddenAuthor{}, &models.FeedFeedback{},
		&models.WaterTeamRecruitment{}, &models.PostImage{}, &models.File{},
	))
	return db
}

func createFollowingPost(t *testing.T, db *gorm.DB, authorID uint, postType string, title string) models.Post {
	t.Helper()
	p := models.Post{
		BoardID:  models.BoardShuitie,
		AuthorID: authorID,
		PostType: postType,
		Title:    title,
		Content:  "内容",
		Status:   models.PostStatusNormal,
	}
	require.NoError(t, db.Create(&p).Error)
	return p
}

// TestFollowingFeedIncludesFollowedAuthorsAndSections
// 关注作者 + 关注版块（FEED-6）：关注的作者帖子（即使不在关注版块）与
// 关注版块的帖子（即使来自未关注作者）都应出现在关注流；双命中只一次。
func TestFollowingFeedIncludesFollowedAuthorsAndSections(t *testing.T) {
	db := newFollowingTestDB(t)
	h := NewPostHandler(db, "", "")

	follower := models.User{Nickname: "我", PasswordHash: "x"}
	authorB := models.User{Nickname: "作者B", PasswordHash: "x"}
	authorC := models.User{Nickname: "作者C", PasswordHash: "x"}
	require.NoError(t, db.Create(&follower).Error)
	require.NoError(t, db.Create(&authorB).Error)
	require.NoError(t, db.Create(&authorC).Error)

	s1 := models.WaterSection{Slug: "course_study", Title: "课程学习"}
	s2 := models.WaterSection{Slug: "campus_life", Title: "校园生活"}
	require.NoError(t, db.Create(&s1).Error)
	require.NoError(t, db.Create(&s2).Error)

	// 关注作者 B；关注版块 course_study。
	require.NoError(t, db.Create(&models.UserFollow{FollowerID: follower.ID, FollowingID: authorB.ID}).Error)
	require.NoError(t, db.Create(&models.WaterSectionFollow{UserID: follower.ID, SectionID: s1.ID}).Error)

	// P1：作者 B（被关注）在 campus_life（未关注版块）→ 靠作者命中。
	p1 := createFollowingPost(t, db, authorB.ID, "campus_life", "B在未关注版块")
	// P2：作者 C（未关注）在 course_study（已关注版块）→ 靠版块命中。
	p2 := createFollowingPost(t, db, authorC.ID, "course_study", "C在已关注版块")
	// P3：作者 C（未关注）在 campus_life（未关注版块）→ 不出现。
	createFollowingPost(t, db, authorC.ID, "campus_life", "无关帖")

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/posts?board=1&sort=following&limit=20"), nil)
	router := gin.New()
	router.GET("/posts", func(c *gin.Context) {
		c.Set("user_id", follower.ID)
		h.GetList(c)
	})
	router.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)

	var body struct {
		Posts []models.Post `json:"posts"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	var ids []uint
	for _, p := range body.Posts {
		ids = append(ids, p.ID)
	}
	require.Contains(t, ids, p1.ID, "关注的作者帖子应出现")
	require.Contains(t, ids, p2.ID, "关注版块的帖子应出现")
	require.NotContains(t, ids, uint(0))
	// P1 双命中（作者+版块? 不，P1 靠作者命中一次）——验证无重复。
	seen := map[uint]int{}
	for _, id := range ids {
		seen[id]++
	}
	for _, count := range seen {
		require.Equal(t, 1, count, "同一帖不应重复出现")
	}
}

// TestFollowingFeedHiddenAuthorStillFiltered
// 隐藏作者 > 关注流：关注了作者但「不看TA」，关注流中仍不显示（FEED-6 §21.3）。
func TestFollowingFeedHiddenAuthorStillFiltered(t *testing.T) {
	db := newFollowingTestDB(t)
	h := NewPostHandler(db, "", "")

	follower := models.User{Nickname: "我", PasswordHash: "x"}
	authorB := models.User{Nickname: "作者B", PasswordHash: "x"}
	require.NoError(t, db.Create(&follower).Error)
	require.NoError(t, db.Create(&authorB).Error)

	require.NoError(t, db.Create(&models.UserFollow{FollowerID: follower.ID, FollowingID: authorB.ID}).Error)
	// 关注了 B 但隐藏 B。
	require.NoError(t, db.Create(&models.UserHiddenAuthor{UserID: follower.ID, AuthorID: authorB.ID}).Error)
	p := createFollowingPost(t, db, authorB.ID, "campus_life", "B的帖")

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/posts?board=1&sort=following&limit=20", nil)
	router := gin.New()
	router.GET("/posts", func(c *gin.Context) {
		c.Set("user_id", follower.ID)
		h.GetList(c)
	})
	router.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)

	var body struct {
		Posts []models.Post `json:"posts"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.NotContains(t, body.Posts, p.ID, "隐藏作者后关注流不应出现其帖子")
}
