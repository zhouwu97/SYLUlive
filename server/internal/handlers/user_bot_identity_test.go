package handlers

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestPublicBotIdentityCannotBeClaimedByNicknameOrProfileJSON(t *testing.T) {
	db := newUserProfileUpdateTestDB(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}, &models.UserFollow{}))
	owner := models.User{ID: 101, Nickname: "公开创建者", AccountStatus: "active", Role: models.RoleUser}
	bot := models.User{ID: 102, Nickname: "名字无需AI前缀", AccountStatus: "bot", Role: models.RoleUser}
	human := models.User{ID: 103, Nickname: "[AI] 大肥鱼", AccountStatus: "active", Role: models.RoleUser}
	for _, user := range []models.User{owner, bot, human} {
		require.NoError(t, db.Create(&user).Error)
	}
	require.NoError(t, db.Create(&models.ManagedBot{OwnerID: owner.ID, UserID: bot.ID, Enabled: true}).Error)
	require.NoError(t, db.Create(&models.UserFollow{FollowerID: human.ID, FollowingID: bot.ID}).Error)
	require.NoError(t, db.Create(&models.UserFollow{FollowerID: bot.ID, FollowingID: human.ID}).Error)
	h := NewUserHandler(db)
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", human.ID) })
	r.GET("/api/user/:id/following", h.GetFollowing)
	r.GET("/api/user/:id/followers", h.GetFollowers)
	r.PUT("/api/user/profile", h.UpdateProfile)
	for _, path := range []string{"/api/user/103/following", "/api/user/103/followers"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
		require.Equal(t, 200, w.Code, w.Body.String())
		var body struct {
			Items []models.PublicUserResponse `json:"items"`
		}
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &body))
		require.Len(t, body.Items, 1)
		require.NotNil(t, body.Items[0].AIBot)
		require.Equal(t, owner.ID, body.Items[0].AIBot.OwnerID)
		require.Equal(t, owner.Nickname, body.Items[0].AIBot.OwnerNickname)
	}
	req := httptest.NewRequest("PUT", "/api/user/profile", strings.NewReader(`{"nickname":"[AI] 假鱼","account_status":"bot","ai_bot":{"owner_id":101,"owner_nickname":"公开创建者"}}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	require.Equal(t, 200, w.Code, w.Body.String())
	var actual models.User
	require.NoError(t, db.First(&actual, human.ID).Error)
	require.Equal(t, "active", actual.AccountStatus)
	require.Nil(t, actual.AIBot)
	raw, err := json.Marshal(models.PublicUser(actual))
	require.NoError(t, err)
	require.NotContains(t, string(raw), "ai_bot")
}
