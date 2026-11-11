package services

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

type ManagedBotUpdate struct {
	Name    *string                  `json:"name"`
	Enabled bool                     `json:"enabled"`
	Avatar  *string                  `json:"avatar"`
	Policy  *models.ManagedBotPolicy `json:"policy"`
}

const ManagedBotMaxDailyReplies = 100
const ManagedBotMinReplyIntervalMinutes = 1

// Legacy rows have no policy. Keep them read-only until the owner explicitly grants participation.
func DefaultManagedBotPolicy() models.ManagedBotPolicy {
	return models.ManagedBotPolicy{PublicReadEnabled: true, AllowedPostTypes: []string{"campus_life", "course_study"}, BlockedTerms: []string{}, BlockLinks: true, DailyReplyLimit: 3, MinReplyIntervalMinutes: 30}
}

func ManagedBotPolicy(bot models.ManagedBot) models.ManagedBotPolicy {
	policy := DefaultManagedBotPolicy()
	if bot.PolicyJSON != "" {
		if json.Unmarshal([]byte(bot.PolicyJSON), &policy) != nil {
			policy = DefaultManagedBotPolicy()
			policy.PublicReadEnabled = false
			policy.AllowedPostTypes = []string{}
		}
	}
	if policy.AllowedPostTypes == nil {
		policy.AllowedPostTypes = []string{}
	}
	if policy.BlockedTerms == nil {
		policy.BlockedTerms = []string{}
	}
	return policy
}

func ManagedBotSectionAllowed(section models.WaterSection) bool {
	return section.Status == "active" && section.Slug != "complaint" && section.Slug != "freshman_help" && (section.SensitiveLevel == "" || section.SensitiveLevel == "normal")
}

func normalizeBotSpeech(value string) string {
	return strings.ToLower(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || unicode.IsSpace(r) {
			return -1
		}
		if r >= '\uff01' && r <= '\uff5e' {
			return r - 0xfee0
		}
		return r
	}, value))
}

func validateManagedBotPolicy(tx *gorm.DB, policy *models.ManagedBotPolicy) error {
	if len(policy.AllowedPostTypes) > 100 || len(policy.BlockedTerms) > 20 || policy.DailyReplyLimit < 1 || policy.DailyReplyLimit > ManagedBotMaxDailyReplies || policy.MinReplyIntervalMinutes < ManagedBotMinReplyIntervalMinutes || policy.MinReplyIntervalMinutes > 1440 {
		return integrationError("invalid_bot_policy", 422)
	}
	seen := map[string]bool{}
	for _, slug := range policy.AllowedPostTypes {
		if seen[slug] || strings.TrimSpace(slug) != slug || len(slug) == 0 || len(slug) > 64 {
			return integrationError("invalid_bot_policy", 422)
		}
		seen[slug] = true
		var section models.WaterSection
		if err := tx.Where("slug = ?", slug).Take(&section).Error; err != nil || !ManagedBotSectionAllowed(section) {
			return integrationError("invalid_bot_section", 422)
		}
	}
	for i, term := range policy.BlockedTerms {
		term = strings.TrimSpace(term)
		if term == "" || utf8.RuneCountInString(term) > 24 || normalizeBotSpeech(term) == "" {
			return integrationError("invalid_bot_policy", 422)
		}
		policy.BlockedTerms[i] = term
	}
	if policy.AllowedPostTypes == nil {
		policy.AllowedPostTypes = []string{}
	}
	if policy.BlockedTerms == nil {
		policy.BlockedTerms = []string{}
	}
	return nil
}

// Only uploaded image resources belonging to this owner can become the bot's public avatar.
func claimManagedBotAvatar(tx *gorm.DB, owner uint, avatar string) (string, error) {
	if avatar == "" {
		return "", nil
	}
	parsed, err := url.Parse(avatar)
	if err != nil || parsed.IsAbs() || parsed.Host != "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || strings.Contains(avatar, "\\") || strings.Contains(avatar, "..") {
		return "", integrationError("invalid_bot_avatar", 422)
	}
	path, ok := normalizeUploadReference(avatar)
	if !ok {
		return "", integrationError("invalid_bot_avatar", 422)
	}
	var file models.File
	if err := tx.Where("path IN ?", []string{path, strings.TrimPrefix(path, "/")}).Take(&file).Error; err != nil {
		return "", integrationError("invalid_bot_avatar", 422)
	}
	if file.UploaderID != owner {
		var count int64
		if err := tx.Model(&models.FileUploadGrant{}).Where("file_id = ? AND user_id = ?", file.ID, owner).Count(&count).Error; err != nil {
			return "", err
		}
		if count == 0 {
			return "", integrationError("invalid_bot_avatar", 422)
		}
	}
	if _, err := ValidateImageFileIDs(tx, []uint{file.ID}, 1, owner); err != nil {
		return "", integrationError("invalid_bot_avatar", 422)
	}
	if err := ClaimPublicImageFiles(tx, []uint{file.ID}); err != nil {
		return "", err
	}
	return path, nil
}

// ManageBot keeps the original API available to internal callers; new clients use UpdateManagedBot.
func (s *IntegrationActionService) ManageBot(ctx context.Context, owner uint, name string, enabled bool) (models.ManagedBot, error) {
	var input ManagedBotUpdate
	input.Enabled = enabled
	if name != "" {
		input.Name = &name
	}
	if !enabled {
		input.Name = nil
	}
	return s.UpdateManagedBot(ctx, owner, input)
}

func (s *IntegrationActionService) UpdateManagedBot(ctx context.Context, owner uint, input ManagedBotUpdate) (models.ManagedBot, error) {
	var bot models.ManagedBot
	pauseOnly := !input.Enabled && input.Name == nil && input.Avatar == nil && input.Policy == nil
	name := ""
	if input.Name != nil {
		name = strings.TrimSpace(*input.Name)
		if name == "" || utf8.RuneCountInString(name) > 24 || strings.IndexFunc(name, func(r rune) bool { return unicode.IsControl(r) || unicode.Is(unicode.Cf, r) }) >= 0 {
			return bot, integrationError("invalid_bot_name", 422)
		}
	}
	err := s.Auth.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&bot, "owner_id = ?", owner).Error
		if pauseOnly {
			if err != nil {
				return err
			}
			bot.Enabled = false
			bot.Revision++
			return tx.Save(&bot).Error
		}
		if _, err := s.Auth.eligible(tx, user, nil); err != nil {
			return err
		}
		if _, err := s.eligibleCommunityRules(tx, user); err != nil {
			return err
		}
		policy := DefaultManagedBotPolicy()
		if err == nil {
			policy = ManagedBotPolicy(bot)
		}
		if input.Policy != nil {
			policy = *input.Policy
			if err := validateManagedBotPolicy(tx, &policy); err != nil {
				return err
			}
		}
		avatar := ""
		if errors.Is(err, gorm.ErrRecordNotFound) {
			if input.Name == nil {
				return integrationError("invalid_bot_name", 422)
			}
			if input.Avatar != nil {
				avatar, err = claimManagedBotAvatar(tx, owner, strings.TrimSpace(*input.Avatar))
				if err != nil {
					return err
				}
			}
			actor := models.User{Nickname: "[AI] " + name, Avatar: avatar, Role: models.RoleUser, AccountStatus: "bot", PasswordHash: "!managed-bot:" + uuid.NewString()}
			if err := createManagedBotActor(tx, &actor); err != nil {
				return err
			}
			bot = models.ManagedBot{OwnerID: owner, UserID: actor.ID, Enabled: input.Enabled, CreatedAt: s.Auth.Now()}
		} else if err != nil {
			return err
		} else {
			var actor models.User
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&actor, bot.UserID).Error; err != nil {
				return err
			}
			if actor.AccountStatus != "bot" || actor.Role != models.RoleUser {
				return integrationError("bot_unavailable", 403)
			}
			updates := map[string]interface{}{}
			if input.Name != nil {
				updates["nickname"] = "[AI] " + name
			}
			if input.Avatar != nil && strings.TrimSpace(*input.Avatar) != actor.Avatar {
				avatar, err = claimManagedBotAvatar(tx, owner, strings.TrimSpace(*input.Avatar))
				if err != nil {
					return err
				}
				updates["avatar"] = avatar
			}
			if len(updates) > 0 {
				if err := tx.Model(&actor).Updates(updates).Error; err != nil {
					return err
				}
			}
		}
		bot.Enabled = input.Enabled
		raw, err := json.Marshal(policy)
		if err != nil {
			return err
		}
		bot.PolicyJSON = string(raw)
		bot.Revision++
		return tx.Save(&bot).Error
	})
	return bot, err
}

func (s *IntegrationActionService) AutoReply(ctx context.Context, b models.IntegrationBinding, p IntegrationProposal) (models.IntegrationAction, error) {
	if !IntegrationHasScope(b, IntegrationAutoReplyScope) {
		return models.IntegrationAction{}, integrationError("insufficient_scope", 403)
	}
	if p.Kind != "reply" || utf8.RuneCountInString(p.Content) > 300 {
		return models.IntegrationAction{}, integrationError("invalid_bot_reply", 422)
	}
	a, err := s.propose(ctx, b, p, true)
	if err != nil {
		return a, err
	}
	return s.decide(ctx, b.OwnerID, a.ID, IntegrationActionDecision{Allow: true, Version: a.Version, PayloadHash: a.PayloadHash}, &b)
}

var managedBotLink = regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://|mailto:|data:|javascript:|tel:|www\.|(?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,63}(?:[/?:#]|$)|(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?:[:/?#]|$))`)

func (s *IntegrationActionService) botActor(tx *gorm.DB, owner uint, now time.Time, post models.Post, p IntegrationProposal) (uint, error) {
	var bot models.ManagedBot
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND enabled = ?", owner, true).Take(&bot).Error; err != nil {
		return 0, integrationError("bot_disabled", 403)
	}
	policy := ManagedBotPolicy(bot)
	if !policy.PublicReadEnabled || (p.Content != "" && !policy.ReplyEnabled) || (p.StickerID != "" && !policy.StickerEnabled) {
		return 0, integrationError("bot_permission_denied", 403)
	}
	allowed := false
	for _, slug := range policy.AllowedPostTypes {
		allowed = allowed || slug == post.PostType
	}
	var section models.WaterSection
	if err := tx.Where("slug = ?", post.PostType).Take(&section).Error; err != nil || !allowed || !ManagedBotSectionAllowed(section) {
		return 0, integrationError("bot_section_denied", 403)
	}
	content := normalizeBotSpeech(p.Content)
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
	currentSection, err := s.section(tx, actor.ID, post.PostType)
	if err != nil {
		return 0, err
	}
	if !ManagedBotSectionAllowed(currentSection) {
		return 0, integrationError("bot_section_denied", 403)
	}
	limit := policy.DailyReplyLimit
	if limit < 1 || limit > ManagedBotMaxDailyReplies {
		limit = 3
	}
	interval := policy.MinReplyIntervalMinutes
	if interval < ManagedBotMinReplyIntervalMinutes {
		interval = ManagedBotMinReplyIntervalMinutes
	}
	var count int64
	if p.ReplyToReplyID == 0 {
		var postAuthor models.User
		if err := tx.Select("id, account_status").First(&postAuthor, post.AuthorID).Error; err != nil {
			return 0, integrationError("source_unavailable", 409)
		}
		if err := tx.Model(&models.ManagedBot{}).Where("user_id = ?", post.AuthorID).Count(&count).Error; err != nil {
			return 0, err
		}
		if post.AuthorID == actor.ID || postAuthor.AccountStatus == "bot" || count != 0 {
			return 0, integrationError("bot_reply_target_not_human", 422)
		}
	}
	if p.ReplyToReplyID != 0 {
		// checkSource has locked and version-checked this same-post target before the bot lock.
		// Only a real non-bot participant may start another turn; bot-to-bot replies loop forever.
		var target models.Reply
		if err := tx.Where("id = ? AND post_id = ? AND status = ?", p.ReplyToReplyID, post.ID, models.ReplyStatusNormal).Take(&target).Error; err != nil {
			return 0, integrationError("source_unavailable", 409)
		}
		var targetAuthor models.User
		if err := tx.Select("id, account_status").First(&targetAuthor, target.AuthorID).Error; err != nil {
			return 0, integrationError("source_unavailable", 409)
		}
		if err := tx.Model(&models.ManagedBot{}).Where("user_id = ?", target.AuthorID).Count(&count).Error; err != nil {
			return 0, err
		}
		if target.AuthorID == actor.ID || targetAuthor.AccountStatus == "bot" || count != 0 {
			return 0, integrationError("bot_reply_target_not_human", 422)
		}
		// Include deleted prior bot replies: deleting public content must not reset participation.
		if err := tx.Model(&models.Reply{}).Where("author_id = ? AND reply_to_reply_id = ?", actor.ID, target.ID).Count(&count).Error; err != nil {
			return 0, err
		}
		if count != 0 {
			return 0, integrationError("bot_reply_already_answered", 409)
		}
	}
	if err := tx.Model(&models.Reply{}).Where("author_id = ? AND created_at > ?", actor.ID, now.Add(-24*time.Hour)).Count(&count).Error; err != nil {
		return 0, err
	}
	if count >= int64(limit) {
		return 0, integrationError("bot_daily_quota", 429)
	}
	query := tx.Model(&models.Reply{}).Where("author_id = ? AND created_at > ?", actor.ID, now.Add(-time.Duration(interval)*time.Minute))
	if p.ReplyToReplyID == 0 {
		// Top-level participation stays once per post; only specific human targets get follow-ups.
		query = tx.Model(&models.Reply{}).Where("author_id = ? AND (post_id = ? OR created_at > ?)", actor.ID, post.ID, now.Add(-time.Duration(interval)*time.Minute))
	}
	if err := query.Count(&count).Error; err != nil {
		return 0, err
	}
	if count > 0 {
		return 0, integrationError("bot_reply_cooldown", 429)
	}
	return actor.ID, nil
}
