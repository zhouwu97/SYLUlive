package services

import (
	"context"
	"encoding/json"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"sync"
	"testing"
	"time"
)

func grantBotParticipation(t *testing.T, db *gorm.DB, bot models.ManagedBot) {
	t.Helper()
	policy := DefaultManagedBotPolicy()
	policy.AllowedPostTypes = []string{"campus_life"}
	policy.ReplyEnabled, policy.StickerEnabled = true, true
	raw, err := json.Marshal(policy)
	require.NoError(t, err)
	require.NoError(t, db.Model(&bot).Update("policy_json", string(raw)).Error)
}

func TestIntegrationBotUniqueActorScopeAndQuota(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	bot, err := s.ManageBot(ctx, 1, "大肥鱼", true)
	require.NoError(t, err)
	again, err := s.ManageBot(ctx, 1, "小鲸鱼", true)
	require.NoError(t, err)
	require.Equal(t, bot.UserID, again.UserID)
	require.NotEqualValues(t, 1, bot.UserID)
	var actor models.User
	require.NoError(t, db.First(&actor, bot.UserID).Error)
	require.Equal(t, models.RoleUser, actor.Role)
	require.Equal(t, "bot", actor.AccountStatus)
	require.Empty(t, actor.Email)
	require.Empty(t, actor.StudentID)
	require.Contains(t, actor.Nickname, "[AI]")
	grantBotParticipation(t, db, bot)
	p := integrationReplyProposal(post)
	_, err = s.AutoReply(ctx, b, p)
	require.EqualError(t, err, "insufficient_scope")
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	a, err := s.AutoReply(ctx, b, p)
	require.NoError(t, err)
	require.Equal(t, "published", a.State)
	var reply models.Reply
	require.NoError(t, db.First(&reply, *a.ReplyID).Error)
	require.Equal(t, bot.UserID, reply.AuthorID)
	require.Contains(t, reply.Content, "[AI机器人]")
	repeated, err := s.AutoReply(ctx, b, p)
	require.NoError(t, err)
	require.Equal(t, a.ReplyID, repeated.ReplyID)
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(post))
	require.EqualError(t, err, "bot_reply_cooldown")
	p.Kind = "post"
	_, err = s.AutoReply(ctx, b, p)
	require.EqualError(t, err, "invalid_bot_reply")
	_, err = s.ManageBot(ctx, 1, "小鲸鱼", false)
	require.NoError(t, err)
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(post))
	require.EqualError(t, err, "bot_disabled")
}

func TestIntegrationBotConcurrentCreationAndSticker(t *testing.T) {
	db, s, b, post := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	var wg sync.WaitGroup
	ids := make(chan uint, 4)
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); bot, err := s.ManageBot(ctx, 1, "鱼", true); ids <- bot.UserID; errs <- err }()
	}
	wg.Wait()
	close(ids)
	close(errs)
	for err := range errs {
		require.NoError(t, err)
	}
	var expected uint
	for id := range ids {
		if expected == 0 {
			expected = id
		}
		require.Equal(t, expected, id)
	}
	grantBotParticipation(t, db, models.ManagedBot{OwnerID: 1})
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	p := integrationReplyProposal(post)
	p.Content = ""
	p.StickerID = "test_sticker"
	a, err := s.AutoReply(ctx, b, p)
	require.NoError(t, err)
	var r models.Reply
	require.NoError(t, db.First(&r, *a.ReplyID).Error)
	require.Equal(t, "test_sticker", *r.StickerID)
	require.Contains(t, r.Content, "AI机器人")
	// 在途读取后的来源删除不允许发布。
	post.Status = models.PostStatusDeleted
	require.NoError(t, db.Save(&post).Error)
	p.OperationID = uuid.NewString()
	_, err = s.AutoReply(ctx, b, p)
	require.EqualError(t, err, "source_unavailable")
}

func TestIntegrationBotDailyQuotaRevocationAndPause(t *testing.T) {
	db, s, b, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	bot, err := s.ManageBot(ctx, 1, "鱼", true)
	require.NoError(t, err)
	grantBotParticipation(t, db, bot)
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	now := time.Now()
	s.Auth.Now = func() time.Time { return now }
	for i := 0; i < 4; i++ {
		post := source
		post.ID = 0
		require.NoError(t, db.Create(&post).Error)
		_, err = s.AutoReply(ctx, b, integrationReplyProposal(post))
		if i < 3 {
			require.NoError(t, err)
		} else {
			require.EqualError(t, err, "bot_daily_quota")
		}
		now = now.Add(31 * time.Minute)
	}
	require.NoError(t, db.Model(&models.IntegrationBinding{}).Where("id = ?", b.ID).Update("state", "revoked").Error)
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(source))
	require.Error(t, err)
	// 身份资格消失不应阻止创建者暂停机器人。
	require.NoError(t, db.Where("user_id = ?", 1).Delete(&models.AcademicIdentityBinding{}).Error)
	bot, err = s.ManageBot(ctx, 1, "", false)
	require.NoError(t, err)
	require.False(t, bot.Enabled)
}
