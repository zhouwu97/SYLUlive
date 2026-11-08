package services

import (
	"context"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	"strings"
	"time"
	"unicode/utf8"
)

// AutoPost 的授权与评论分开；旧 bot_reply 不能升级为发帖或上传权限。
func (s *IntegrationActionService) AutoPost(ctx context.Context, b models.IntegrationBinding, p IntegrationProposal) (models.IntegrationAction, error) {
	if !IntegrationHasScope(b, IntegrationAutoPostScope) {
		return models.IntegrationAction{}, integrationError("insufficient_scope", 403)
	}
	if p.Kind != "post" || len(p.Sources) == 0 || utf8.RuneCountInString(p.Content) > 1500 {
		return models.IntegrationAction{}, integrationError("invalid_bot_post", 422)
	}
	a, err := s.propose(ctx, b, p, true)
	if err != nil {
		return a, err
	}
	return s.decide(ctx, b.OwnerID, a.ID, IntegrationActionDecision{Allow: true, Version: a.Version, PayloadHash: a.PayloadHash}, &b)
}

func (s *IntegrationActionService) botPostActor(tx *gorm.DB, owner uint, now time.Time, p IntegrationProposal) (uint, error) {
	var bot models.ManagedBot
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND enabled = ?", owner, true).Take(&bot).Error; err != nil {
		return 0, integrationError("bot_disabled", 403)
	}
	policy := ManagedBotPolicy(bot)
	if !policy.PublicReadEnabled || !policy.PostEnabled || (len(p.ImageFileIDs) > 0 && !policy.ImageEnabled) {
		return 0, integrationError("bot_permission_denied", 403)
	}
	allowed := map[string]bool{}
	for _, slug := range policy.AllowedPostTypes {
		allowed[slug] = true
	}
	sections := []string{p.PostType}
	for _, source := range p.Sources {
		var post models.Post
		if err := tx.First(&post, source.PostID).Error; err != nil {
			return 0, err
		}
		sections = append(sections, post.PostType)
	}
	for _, slug := range sections {
		var section models.WaterSection
		if err := tx.Where("slug = ?", slug).Take(&section).Error; err != nil || !allowed[slug] || !ManagedBotSectionAllowed(section) {
			return 0, integrationError("bot_section_denied", 403)
		}
	}
	content := normalizeBotSpeech(p.Title + "\n" + p.Content)
	for _, term := range policy.BlockedTerms {
		if needle := normalizeBotSpeech(term); needle != "" && strings.Contains(content, needle) {
			return 0, integrationError("bot_speech_blocked", 422)
		}
	}
	if policy.BlockLinks && managedBotLink.MatchString(content) {
		return 0, integrationError("bot_links_blocked", 422)
	}
	var actor models.User
	if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).First(&actor, bot.UserID).Error; err != nil {
		return 0, err
	}
	if actor.AccountStatus != "bot" || actor.Role != models.RoleUser || actor.CreditScore <= 0 {
		return 0, integrationError("bot_unavailable", 403)
	}
	if _, err := s.section(tx, actor.ID, p.PostType); err != nil {
		return 0, err
	}
	var count int64
	if err := tx.Unscoped().Model(&models.Post{}).Where("author_id = ? AND created_at > ?", actor.ID, now.Add(-24*time.Hour)).Count(&count).Error; err != nil {
		return 0, err
	}
	if count != 0 {
		return 0, integrationError("bot_post_daily_quota", 429)
	}
	return actor.ID, nil
}

func (s *IntegrationActionService) checkBotImages(tx *gorm.DB, actor uint, ids []uint) error {
	for _, id := range ids {
		var file models.File
		if err := tx.First(&file, id).Error; err != nil {
			return integrationError("invalid_image_reference", 422)
		}
		if file.UploaderID != actor {
			var count int64
			if err := tx.Model(&models.FileUploadGrant{}).Where("file_id = ? AND user_id = ?", id, actor).Count(&count).Error; err != nil {
				return err
			}
			if count == 0 {
				return integrationError("invalid_image_reference", 422)
			}
		}
	}
	return nil
}

// BotUploadActor 只解析当前有效授权的独立机器人；文件上传不继承创建者账号。
func (s *IntegrationActionService) BotUploadActor(ctx context.Context, expected models.IntegrationBinding) (uint, error) {
	return s.BotPublicationActor(ctx, expected, true)
}

func (s *IntegrationActionService) BotPublicationActor(ctx context.Context, expected models.IntegrationBinding, image bool) (uint, error) {
	var actor uint
	err := s.Auth.ownerTx(ctx, expected.OwnerID, func(tx *gorm.DB, user models.User) error {
		b, err := s.activeBinding(tx, user, expected.ID, expected.Epoch)
		if err != nil {
			return err
		}
		if !IntegrationHasScope(b, IntegrationAutoPostScope) {
			return integrationError("insufficient_scope", 403)
		}
		if _, err := s.eligibleCommunityRules(tx, user); err != nil {
			return err
		}
		var bot models.ManagedBot
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND enabled = ?", user.ID, true).Take(&bot).Error; err != nil {
			return integrationError("bot_disabled", 403)
		}
		policy := ManagedBotPolicy(bot)
		if !policy.PublicReadEnabled || !policy.PostEnabled || (image && !policy.ImageEnabled) {
			return integrationError("bot_permission_denied", 403)
		}
		var target models.User
		if err := tx.First(&target, bot.UserID).Error; err != nil {
			return err
		}
		if target.AccountStatus != "bot" || target.Role != models.RoleUser || target.CreditScore <= 0 {
			return integrationError("bot_unavailable", 403)
		}
		actor = bot.UserID
		return nil
	})
	return actor, err
}
