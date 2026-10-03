package handlers

import (
	"encoding/json"
	"fmt"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"net/http"
	"net/http/httptest"
	"shenliyuan/internal/models"
	"testing"
	"time"
)

func TestBookmarksIdempotencyAndIsolation(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.PostBookmark{}))
	h := NewPostHandler(db, "", "")
	post := models.Post{AuthorID: 1, BoardID: models.BoardShuitie, Content: "测试", Status: models.PostStatusNormal}
	require.NoError(t, db.Create(&post).Error)
	params := gin.Params{{Key: "id", Value: fmt.Sprint(post.ID)}}
	for i := 0; i < 2; i++ {
		c, w := feedCtx(1, params)
		h.PutBookmark(c)
		require.Equal(t, http.StatusOK, w.Code)
	}
	var count int64
	require.NoError(t, db.Model(&models.PostBookmark{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	c, w := feedCtx(2, params)
	h.DeleteBookmark(c)
	require.Equal(t, http.StatusOK, w.Code)
	require.NoError(t, db.Model(&models.PostBookmark{}).Count(&count).Error)
	require.EqualValues(t, 1, count)
	for i := 0; i < 2; i++ {
		c, w := feedCtx(1, params)
		h.DeleteBookmark(c)
		require.Equal(t, http.StatusOK, w.Code)
	}
	require.NoError(t, db.Model(&models.PostBookmark{}).Count(&count).Error)
	require.Zero(t, count)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
	c, w = feedCtx(1, params)
	h.PutBookmark(c)
	require.Equal(t, http.StatusNotFound, w.Code)
}

// TestListBookmarksOrderingEnvelopeAndIsolation 补齐 ListBookmarks 的行为覆盖：
// 路由此前从未注册（网页端「我的收藏」因此 404），该 handler 首次被真实调用。
// 列表必须按收藏时间倒序、只含当前用户的收藏，并复用 GetList 的包络字段。
func TestListBookmarksOrderingEnvelopeAndIsolation(t *testing.T) {
	db := newFeedSnapshotTestDB(t)
	// 收藏表与 hydrate 链路涉及的旁路表（水帖版块、点赞）一并迁移，
	// 与 GetList 系测试保持同等的真实度。
	require.NoError(t, db.AutoMigrate(
		&models.PostBookmark{}, &models.Like{},
		&models.WaterSection{}, &models.WaterSectionFollow{}, &models.WaterTeamRecruitment{},
	))
	h := NewPostHandler(db, "", "")

	author := models.User{Nickname: "作者", PasswordHash: "x"}
	userA := models.User{Nickname: "甲", PasswordHash: "x"}
	userB := models.User{Nickname: "乙", PasswordHash: "x"}
	require.NoError(t, db.Create(&author).Error)
	require.NoError(t, db.Create(&userA).Error)
	require.NoError(t, db.Create(&userB).Error)

	p1 := models.Post{AuthorID: author.ID, BoardID: models.BoardShuitie, PostType: "campus_life", Title: "较早收藏", Content: "测试", Status: models.PostStatusNormal}
	p2 := models.Post{AuthorID: author.ID, BoardID: models.BoardShuitie, PostType: "campus_life", Title: "较晚收藏", Content: "测试", Status: models.PostStatusNormal}
	require.NoError(t, db.Create(&p1).Error)
	require.NoError(t, db.Create(&p2).Error)

	now := time.Now()
	require.NoError(t, db.Create(&models.PostBookmark{UserID: userA.ID, PostID: p1.ID, CreatedAt: now.Add(-2 * time.Hour)}).Error)
	require.NoError(t, db.Create(&models.PostBookmark{UserID: userA.ID, PostID: p2.ID, CreatedAt: now.Add(-time.Hour)}).Error)
	// 用户乙收藏了同一帖 p1：不应出现在甲的列表里。
	require.NoError(t, db.Create(&models.PostBookmark{UserID: userB.ID, PostID: p1.ID, CreatedAt: now}).Error)

	readList := func(userID uint) ([]models.Post, int, bool) {
		c, w := feedCtx(userID, nil)
		h.ListBookmarks(c)
		require.Equal(t, http.StatusOK, w.Code)
		var body struct {
			Posts   []models.Post `json:"posts"`
			Page    int           `json:"page"`
			HasMore bool          `json:"has_more"`
		}
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
		return body.Posts, body.Page, body.HasMore
	}

	posts, page, hasMore := readList(userA.ID)
	require.Len(t, posts, 2)
	require.Equal(t, p2.ID, posts[0].ID, "最近收藏的应排在最前")
	require.Equal(t, p1.ID, posts[1].ID)
	require.Equal(t, 1, page)
	require.False(t, hasMore)

	postsB, _, _ := readList(userB.ID)
	require.Len(t, postsB, 1, "收藏列表必须按用户隔离")
	require.Equal(t, p1.ID, postsB[0].ID)

	// 分页参数非法按契约返回 400（page 最小为 1）。
	c, w := feedCtx(userA.ID, nil)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/user/bookmarks?page=0", nil)
	h.ListBookmarks(c)
	require.Equal(t, http.StatusBadRequest, w.Code)
}
