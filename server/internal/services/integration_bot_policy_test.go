package services

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"shenliyuan/internal/models"
)

func TestManagedBotExpandedQuotaPublishesHundredAndEnforcesMinute(t *testing.T) {
	db, s, binding, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	ctx := context.Background()
	name := "活跃机器人"
	policy := DefaultManagedBotPolicy()
	policy.ReplyEnabled = true
	policy.AllowedPostTypes = []string{"campus_life"}
	policy.DailyReplyLimit, policy.MinReplyIntervalMinutes = 100, 1
	bot, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Enabled: true, Policy: &policy})
	require.NoError(t, err)
	binding.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&binding).Error)
	now := time.Now()
	s.Auth.Now = func() time.Time { return now }
	for i := 0; i < 101; i++ {
		post := source
		post.ID = 0
		require.NoError(t, db.Create(&post).Error)
		proposal := integrationReplyProposal(post)
		action, err := s.AutoReply(ctx, binding, proposal)
		if i == 100 {
			require.EqualError(t, err, "bot_daily_quota")
			break
		}
		require.NoError(t, err, "reply %d must not hit the old 20-publication/30-draft caps", i+1)
		if i == 0 {
			proposal.OperationID = uuid.NewString()
			now = now.Add(59 * time.Second)
			_, err = s.AutoReply(ctx, binding, proposal)
			require.EqualError(t, err, "bot_reply_cooldown")
			now = now.Add(-59 * time.Second)
		}
		// 重试成功操作只取回原结果，不能再次消费评论额度。
		if i == 99 {
			repeated, err := s.AutoReply(ctx, binding, proposal)
			require.NoError(t, err)
			require.Equal(t, action.ReplyID, repeated.ReplyID)
		}
		now = now.Add(time.Minute)
	}
	var count int64
	require.NoError(t, db.Model(&models.Reply{}).Where("author_id = ?", bot.UserID).Count(&count).Error)
	require.EqualValues(t, 100, count)
}

func TestManagedBotPolicyDefaultsEditingAndRevocation(t *testing.T) {
	db, s, b, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	name := "校友鱼"
	ctx := context.Background()
	bot, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Enabled: false})
	require.NoError(t, err)
	require.False(t, bot.Enabled)
	policy := ManagedBotPolicy(bot)
	require.True(t, policy.PublicReadEnabled)
	require.False(t, policy.ReplyEnabled)
	require.False(t, policy.StickerEnabled)
	require.NoError(t, db.Model(&b).Update("scopes", b.Scopes+" "+IntegrationAutoReplyScope).Error)
	b.Scopes += " " + IntegrationAutoReplyScope
	bot, err = s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Enabled: true})
	require.NoError(t, err)
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(source))
	require.EqualError(t, err, "bot_permission_denied")
	policy.AllowedPostTypes = []string{"campus_life"}
	policy.ReplyEnabled = true
	policy.BlockedTerms = []string{"禁止广告", "Secret"}
	bot, err = s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Enabled: true, Policy: &policy})
	require.NoError(t, err)
	// A new service instance must retrieve persisted policy, rather than process-local defaults.
	restarted := &IntegrationActionService{Auth: NewIntegrationAuthService(db), ValidSticker: s.ValidSticker}
	var stored models.ManagedBot
	require.NoError(t, db.First(&stored, "owner_id = ?", 1).Error)
	require.Equal(t, policy, ManagedBotPolicy(stored))
	for _, content := range []string{"禁止\u200b广告", "s E c R e T", "ＳＥＣＲＥＴ"} {
		p := integrationReplyProposal(source)
		p.Content = content
		_, err := restarted.AutoReply(ctx, b, p)
		require.EqualError(t, err, "bot_speech_blocked", content)
	}
	for _, content := range []string{"看https://example.com", "看ＨＴＴＰＳ：／／example.com", "w\u200bw\u200bw.example.cn", "访问example.top", "ftp://example.invalid", "127.0.0.1:8080", "mailto:me@example.invalid"} {
		p := integrationReplyProposal(source)
		p.Content = content
		_, err := restarted.AutoReply(ctx, b, p)
		require.EqualError(t, err, "bot_links_blocked", content)
	}
	p := integrationReplyProposal(source)
	p.Content, p.StickerID = "", "test_sticker"
	_, err = restarted.AutoReply(ctx, b, p)
	require.EqualError(t, err, "bot_permission_denied")
	// The final publication transaction must re-read current permissions after a draft was created.
	p = integrationReplyProposal(source)
	draft, err := s.Propose(ctx, b, p)
	require.NoError(t, err)
	policy.PublicReadEnabled, policy.ReplyEnabled = false, false
	_, err = s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Enabled: true, Policy: &policy})
	require.NoError(t, err)
	_, err = s.decide(ctx, 1, draft.ID, IntegrationActionDecision{Allow: true, Version: draft.Version, PayloadHash: draft.PayloadHash}, &b)
	require.EqualError(t, err, "bot_permission_denied")
	var n int64
	require.NoError(t, db.Model(&models.Reply{}).Count(&n).Error)
	require.Zero(t, n)
	// An unrelated owner never changes this bot, including with a pause-only request.
	integrationTestUser(t, db, 100)
	_, err = s.UpdateManagedBot(ctx, 100, ManagedBotUpdate{Enabled: false})
	require.Error(t, err)
	require.NoError(t, db.First(&stored, "owner_id = ?", 1).Error)
	require.True(t, stored.Enabled)
}

func TestManagedBotLinkRulesRecognizeBroadLinksWithoutBlockingNormalText(t *testing.T) {
	for _, value := range []string{"foo.online", "www.example.zip", "foo.cc", "https://foo.online", "ＨＴＴＰＳ：／／ｆｏｏ．\u200bｏｎｌｉｎｅ", "mailto:me@example.invalid", "custom://resource", "127.0.0.1:8080"} {
		require.True(t, managedBotLink.MatchString(normalizeBotSpeech(value)), value)
	}
	for _, value := range []string{"校园生活讨论", "下课一起吃饭吧", "版本 1.2.3", "学习小组：一起写作业"} {
		require.False(t, managedBotLink.MatchString(normalizeBotSpeech(value)), value)
	}
}

func TestManagedBotPolicyValidationAndCustomQuota(t *testing.T) {
	db, s, b, source := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}))
	require.NoError(t, db.Create(&models.WaterSection{Slug: "complaint", Title: "投诉", Status: "active"}).Error)
	name := "鱼"
	ctx := context.Background()
	policy := DefaultManagedBotPolicy()
	policy.AllowedPostTypes = []string{"campus_life"}
	policy.ReplyEnabled = true
	policy.DailyReplyLimit = 1
	policy.MinReplyIntervalMinutes = 60
	for _, mutate := range []func(*models.ManagedBotPolicy){
		func(p *models.ManagedBotPolicy) { p.DailyReplyLimit = 101 },
		func(p *models.ManagedBotPolicy) { p.DailyReplyLimit = 0 },
		func(p *models.ManagedBotPolicy) { p.MinReplyIntervalMinutes = 0 },
		func(p *models.ManagedBotPolicy) { p.MinReplyIntervalMinutes = 1441 },
		func(p *models.ManagedBotPolicy) { p.AllowedPostTypes = []string{"campus_life", "campus_life"} },
		func(p *models.ManagedBotPolicy) { p.BlockedTerms = []string{"\u200b"} },
	} {
		bad := policy
		mutate(&bad)
		_, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Policy: &bad})
		require.EqualError(t, err, "invalid_bot_policy")
	}
	bad := policy
	bad.AllowedPostTypes = []string{"complaint"}
	_, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Policy: &bad})
	require.EqualError(t, err, "invalid_bot_section")
	bot, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Enabled: true, Policy: &policy})
	require.NoError(t, err)
	// Old clients omitting policy must preserve the owner's speech restrictions and stricter quota.
	_, err = s.ManageBot(ctx, 1, "新鱼", true)
	require.NoError(t, err)
	require.NoError(t, db.First(&bot, "owner_id = ?", 1).Error)
	require.Equal(t, policy, ManagedBotPolicy(bot))
	b.Scopes += " " + IntegrationAutoReplyScope
	require.NoError(t, db.Save(&b).Error)
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(source))
	require.NoError(t, err)
	source.ID = 0
	require.NoError(t, db.Create(&source).Error)
	s.Auth.Now = func() time.Time { return time.Now().Add(61 * time.Minute) }
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(source))
	require.EqualError(t, err, "bot_daily_quota")
	// Raising the daily quota must still preserve the owner's longer interval.
	require.NoError(t, db.Model(&bot).Update("policy_json", func() string { policy.DailyReplyLimit = 3; raw, _ := json.Marshal(policy); return string(raw) }()).Error)
	s.Auth.Now = func() time.Time { return time.Now().Add(31 * time.Minute) }
	_, err = s.AutoReply(ctx, b, integrationReplyProposal(source))
	require.EqualError(t, err, "bot_reply_cooldown")
}

func TestManagedBotAvatarUploadOwnershipAndRollback(t *testing.T) {
	db, s, _, _ := integrationActionFixture(t)
	require.NoError(t, db.AutoMigrate(&models.ManagedBot{}, &models.File{}, &models.FileUploadGrant{}, &models.ImageVariant{}))
	name := "鱼"
	ctx := context.Background()
	for _, avatar := range []string{"https://evil.invalid/a.png", "//evil.invalid/a.png", "/uploads/../secret.png", "/uploads/missing.png", "data:image/png;base64,abc", "/uploads/a.png?token=secret"} {
		_, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Avatar: &avatar})
		require.EqualError(t, err, "invalid_bot_avatar", avatar)
	}
	dir := t.TempDir()
	// Existing upload validators resolve stored uploads relative to the service working directory.
	uploads := filepath.Join("uploads", "bot-test-"+filepath.Base(dir)+".png")
	require.NoError(t, os.MkdirAll("uploads", 0755))
	require.NoError(t, os.WriteFile(uploads, []byte("synthetic-image-bytes"), 0600))
	t.Cleanup(func() { _ = os.Remove(uploads) })
	file := models.File{Hash: filepath.Base(dir), Path: "/" + filepath.ToSlash(uploads), MimeType: "image/png", UploaderID: 2, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate}
	require.NoError(t, db.Create(&file).Error)
	_, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Avatar: &file.Path})
	require.EqualError(t, err, "invalid_bot_avatar")
	require.NoError(t, db.Model(&file).Update("uploader_id", 1).Error)
	bot, err := s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Avatar: &file.Path})
	require.NoError(t, err)
	require.False(t, bot.Enabled)
	var actor models.User
	require.NoError(t, db.First(&actor, bot.UserID).Error)
	require.Equal(t, file.Path, actor.Avatar)
	require.NoError(t, db.First(&file, file.ID).Error)
	require.Equal(t, models.FileAccessPublic, file.AccessScope)
	require.Equal(t, models.FileStatusActive, file.Status)
	empty := ""
	_, err = s.UpdateManagedBot(ctx, 1, ManagedBotUpdate{Name: &name, Avatar: &empty})
	require.NoError(t, err)
	require.NoError(t, db.First(&actor, bot.UserID).Error)
	require.Empty(t, actor.Avatar)
}
