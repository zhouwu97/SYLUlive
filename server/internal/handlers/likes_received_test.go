package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestReceivedLikesOwnershipVisibilityAndCursor(t *testing.T) {
	db := newReplyTestDB(t)
	post, reply, _ := likeTestFixture(t, db)
	other := models.Post{AuthorID: 2, Title: "他人的帖子", Status: models.PostStatusNormal, BoardID: models.BoardShuitie}
	require.NoError(t, db.Create(&other).Error)
	deleted := models.Reply{AuthorID: 1, PostID: post.ID, Content: "删除的评论", Status: models.ReplyStatusDeleted}
	require.NoError(t, db.Create(&deleted).Error)
	likes := []models.Like{
		{UserID: 2, TargetType: "post", TargetID: post.ID},
		{UserID: 2, TargetType: "reply", TargetID: reply.ID},
		{UserID: 1, TargetType: "post", TargetID: post.ID},
		{UserID: 1, TargetType: "post", TargetID: other.ID},
		{UserID: 2, TargetType: "reply", TargetID: deleted.ID},
	}
	require.NoError(t, db.Create(&likes).Error)
	request := func(query string) map[string]interface{} {
		recorder := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(recorder)
		c.Set("user_id", uint(1))
		c.Request = httptest.NewRequest(http.MethodGet, "/api/user/likes/received"+query, nil)
		NewLikeHandler(db).GetReceivedLikes(c)
		require.Equal(t, 200, recorder.Code)
		body := map[string]interface{}{}
		require.NoError(t, json.Unmarshal(recorder.Body.Bytes(), &body))
		require.NotContains(t, recorder.Body.String(), "student_id")
		require.NotContains(t, recorder.Body.String(), "email")
		return body
	}
	first := request("?limit=1&user_id=2")
	require.Equal(t, true, first["has_more"])
	items := first["items"].([]interface{})
	require.Equal(t, "reply", items[0].(map[string]interface{})["target_type"])
	second := request("?limit=1&cursor=" + first["next_cursor"].(string))
	require.Equal(t, false, second["has_more"])
	require.Equal(t, "post", second["items"].([]interface{})[0].(map[string]interface{})["target_type"])
	require.NoError(t, db.Delete(&likes[1]).Error)
	require.Len(t, request("")["items"], 1)
	for _, status := range []models.PostStatus{models.PostStatusSold, models.PostStatusClosed} {
		require.NoError(t, db.Model(&post).Update("status", status).Error)
		require.Len(t, request("")["items"], 1)
	}
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", 2).Update("account_status", "cancelled").Error)
	require.Empty(t, request("")["items"])
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", 2).Update("account_status", "active").Error)
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusModeratedHidden).Error)
	require.Empty(t, request("")["items"])
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusDeleted).Error)
	require.Empty(t, request("")["items"])
}

func TestReceivedLikesRejectsInvalidPagination(t *testing.T) {
	db := newReplyTestDB(t)
	for _, query := range []string{"?limit=0", "?limit=x", "?cursor=0", "?cursor=-1", "?cursor=oops"} {
		recorder := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(recorder)
		c.Set("user_id", uint(1))
		c.Request = httptest.NewRequest("GET", "/api/user/likes/received"+query, nil)
		NewLikeHandler(db).GetReceivedLikes(c)
		require.Equal(t, 400, recorder.Code)
	}
}
