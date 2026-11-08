package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func callReceivedLikesHandler(t *testing.T, handler gin.HandlerFunc, actor, id uint, method string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", actor)
	c.Set("role", "user")
	c.Params = gin.Params{{Key: "id", Value: fmt.Sprint(id)}}
	c.Request = httptest.NewRequest(method, "/test", nil)
	handler(c)
	return w
}

func assertReceivedLikesTotal(t *testing.T, db *gorm.DB, uid uint, want int) {
	t.Helper()
	w := callReceivedLikesHandler(t, NewUserHandler(db).GetUserInfo, uid, uid, http.MethodGet)
	require.Equal(t, http.StatusOK, w.Code, w.Body.String())
	var public models.PublicUserResponse
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &public))
	require.Equal(t, want, public.TotalLikesReceived, "公开主页必须统计有效点赞")
	var user models.User
	require.NoError(t, db.First(&user, uid).Error)
	self, err := selfUserResponseForDB(db, user)
	require.NoError(t, err)
	require.Equal(t, want, self.TotalLikesReceived, "本人资料/登录响应必须使用相同口径")
	w = callReceivedLikesHandler(t, NewLikeHandler(db).GetReceivedLikes, uid, 0, http.MethodGet)
	require.Equal(t, http.StatusOK, w.Code, w.Body.String())
	var likes struct {
		Items []json.RawMessage `json:"items"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &likes))
	require.Len(t, likes.Items, want, "总数与明细一致")
}

func newReceivedLikesDB(t *testing.T) *gorm.DB {
	db := newReplyTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.UserFollow{}, &models.UserLegalConsent{},
		&models.PostImage{}, &models.PostRectificationReview{}, &models.Appeal{}))
	return db
}

func TestReceivedLikesTotalsAfterDeletionAndRepeatedDeletion(t *testing.T) {
	for _, target := range []string{"post", "reply"} {
		t.Run(target, func(t *testing.T) {
			db := newReceivedLikesDB(t)
			post, reply, _ := likeTestFixture(t, db)
			// 帖子与评论来自不同作者，整帖删除必须同时影响两人的统计。
			createMessageTestUser(t, db, 3, "评论作者")
			require.NoError(t, db.Model(&reply).Update("author_id", 3).Error)
			h := NewLikeHandler(db)
			require.Equal(t, 201, callReceivedLikesHandler(t, h.LikePost, 2, post.ID, http.MethodPost).Code)
			require.Equal(t, 201, callReceivedLikesHandler(t, h.LikeReply, 2, reply.ID, http.MethodPost).Code)
			assertReceivedLikesTotal(t, db, 1, 1)
			assertReceivedLikesTotal(t, db, 3, 1)
			handler, id := NewPostHandler(db, "", "").Delete, post.ID
			if target == "reply" {
				handler, id = NewReplyHandler(db, "", "").Delete, reply.ID
			}
			for i := 0; i < 2; i++ {
				actor := uint(1)
				if target == "reply" {
					actor = 3
				}
				w := callReceivedLikesHandler(t, handler, actor, id, http.MethodDelete)
				require.Equal(t, 200, w.Code, w.Body.String())
				want := 0
				if target == "reply" {
					want = 1
				}
				assertReceivedLikesTotal(t, db, 1, want)
				assertReceivedLikesTotal(t, db, 3, 0)
			}
		})
	}
}

func TestReceivedLikesTotalsExcludeSelfAndRepairStaleValues(t *testing.T) {
	db := newReceivedLikesDB(t)
	post, reply, _ := likeTestFixture(t, db)
	h := NewLikeHandler(db)
	require.Equal(t, 201, callReceivedLikesHandler(t, h.LikePost, 1, post.ID, http.MethodPost).Code)
	require.Equal(t, 201, callReceivedLikesHandler(t, h.LikeReply, 1, reply.ID, http.MethodPost).Code)
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", 1).Update("total_likes_received", 122).Error)
	assertReceivedLikesTotal(t, db, 1, 0)
	require.Equal(t, 201, callReceivedLikesHandler(t, h.LikePost, 2, post.ID, http.MethodPost).Code)
	assertReceivedLikesTotal(t, db, 1, 1)
	require.Equal(t, 200, callReceivedLikesHandler(t, h.UnlikePost, 1, post.ID, http.MethodDelete).Code)
	assertReceivedLikesTotal(t, db, 1, 1)
	require.Equal(t, 200, callReceivedLikesHandler(t, h.UnlikePost, 2, post.ID, http.MethodDelete).Code)
	assertReceivedLikesTotal(t, db, 1, 0)
}

func TestReceivedLikesTotalsTrackVisibilityAndLikerCancellation(t *testing.T) {
	db := newReceivedLikesDB(t)
	post, reply, _ := likeTestFixture(t, db)
	h := NewLikeHandler(db)
	require.Equal(t, 201, callReceivedLikesHandler(t, h.LikePost, 2, post.ID, http.MethodPost).Code)
	require.Equal(t, 201, callReceivedLikesHandler(t, h.LikeReply, 2, reply.ID, http.MethodPost).Code)
	for _, state := range []struct {
		status models.PostStatus
		want   int
	}{
		{models.PostStatusModeratedHidden, 0}, {models.PostStatusNormal, 2},
		{models.PostStatusSold, 2}, {models.PostStatusClosed, 2}, {models.PostStatusDeleted, 0},
		{models.PostStatusNormal, 2},
	} {
		require.NoError(t, db.Model(&post).Update("status", state.status).Error)
		assertReceivedLikesTotal(t, db, 1, state.want)
	}
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", 2).Update("account_status", "cancelled").Error)
	assertReceivedLikesTotal(t, db, 1, 0)
}

func TestReceivedLikesRefreshSessionDoesNotReturnHistoricalCounter(t *testing.T) {
	db := newReceivedLikesDB(t)
	require.NoError(t, db.AutoMigrate(&models.RefreshToken{}))
	post, _, _ := likeTestFixture(t, db)
	require.NoError(t, db.Create(&models.Like{UserID: 2, TargetType: "post", TargetID: post.ID}).Error)
	require.NoError(t, db.Model(&models.User{}).Where("id = ?", 1).Update("total_likes_received", 122).Error)
	h := NewAuthHandler(db, "received-likes-fixture")
	c, _ := gin.CreateTestContext(httptest.NewRecorder())
	c.Request = httptest.NewRequest(http.MethodPost, "/api/refresh", nil)
	raw, _, err := h.issueRefreshSession(1, c)
	require.NoError(t, err)
	// 模拟内容在上次资料读取后被删除，旧存储计数仍为 122。
	require.NoError(t, db.Model(&post).Update("status", models.PostStatusDeleted).Error)
	body, err := json.Marshal(map[string]string{"refresh_token": raw})
	require.NoError(t, err)
	w := httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/refresh", strings.NewReader(string(body)))
	c.Request.Header.Set("Content-Type", "application/json")
	h.Refresh(c)
	require.Equal(t, http.StatusOK, w.Code, w.Body.String())
	var payload struct {
		User SelfUserResponse `json:"user"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &payload))
	require.Equal(t, uint(1), payload.User.ID)
	require.Zero(t, payload.User.TotalLikesReceived)
}
