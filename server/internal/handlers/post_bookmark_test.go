package handlers

import (
	"fmt"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"net/http"
	"shenliyuan/internal/models"
	"testing"
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
