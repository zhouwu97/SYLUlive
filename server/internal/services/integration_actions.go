package services

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/community"
	"shenliyuan/internal/models"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

type IntegrationPostSource struct {
	PostID  uint   `json:"post_id"`
	Version string `json:"source_version"`
}

type IntegrationProposal struct {
	RuntimeSessionID   string                  `json:"runtime_session_id,omitempty"`
	BotRevision        uint64                  `json:"bot_revision,omitempty"`
	ImageFileIDs       []uint                  `json:"image_file_ids,omitempty"`
	Sources            []IntegrationPostSource `json:"sources,omitempty"`
	OperationID        string                  `json:"operation_id"`
	Kind               string                  `json:"kind"`
	Title              string                  `json:"title,omitempty"`
	Content            string                  `json:"content"`
	PostType           string                  `json:"post_type,omitempty"`
	PostID             uint                    `json:"post_id,omitempty"`
	SourceVersion      string                  `json:"source_version,omitempty"`
	ReplyToReplyID     uint                    `json:"reply_to_reply_id,omitempty"`
	ReplySourceVersion string                  `json:"reply_source_version,omitempty"`
	StickerID          string                  `json:"sticker_id,omitempty"`
}
type IntegrationActionDecision struct {
	Allow       bool   `json:"allow"`
	Nonce       string `json:"confirmation_nonce"`
	Version     uint   `json:"draft_version"`
	PayloadHash string `json:"payload_hash"`
}
type IntegrationActionPreview struct {
	Action                models.IntegrationAction `json:"action"`
	Nonce                 string                   `json:"confirmation_nonce,omitempty"`
	ConfirmationExpiresAt *time.Time               `json:"confirmation_expires_at,omitempty"`
}
type IntegrationActionService struct {
	Auth             *IntegrationAuthService
	ValidSticker     func(string) bool
	AfterReplyCommit func(models.Notification)
}

func (s *IntegrationActionService) checkSource(tx *gorm.DB, p IntegrationProposal) (models.Post, *models.Reply, error) {
	if p.Kind == "post" {
		for _, source := range p.Sources {
			if _, _, err := s.checkSource(tx, IntegrationProposal{Kind: "reply", PostID: source.PostID, SourceVersion: source.Version}); err != nil {
				return models.Post{}, nil, err
			}
		}
		return models.Post{}, nil, nil
	}
	var post models.Post
	err := community.VisiblePosts(tx).Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Where("id = ?", p.PostID).Take(&post).Error
	if err != nil {
		return post, nil, integrationError("source_unavailable", 409)
	}
	if community.PostDTO(post, 10000).SourceVersion != p.SourceVersion {
		return post, nil, integrationError("source_changed", 409)
	}
	if p.ReplyToReplyID == 0 {
		return post, nil, nil
	}
	var reply models.Reply
	if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Where("id = ? AND post_id = ? AND status = ?", p.ReplyToReplyID, p.PostID, models.ReplyStatusNormal).Take(&reply).Error; err != nil {
		return post, nil, integrationError("source_unavailable", 409)
	}
	if community.ReplyDTO(reply).SourceVersion != p.ReplySourceVersion {
		return post, nil, integrationError("source_changed", 409)
	}
	if reply.ParentReplyID != nil {
		var root models.Reply
		if err := tx.Where("id = ? AND post_id = ? AND parent_reply_id IS NULL", *reply.ParentReplyID, p.PostID).Take(&root).Error; err != nil {
			return post, nil, integrationError("source_unavailable", 409)
		}
	}
	return post, &reply, nil
}

func (s *IntegrationActionService) normalize(p *IntegrationProposal) error {
	if p.RuntimeSessionID != "" || p.BotRevision != 0 {
		if _, err := uuid.Parse(p.RuntimeSessionID); err != nil || p.BotRevision == 0 {
			return integrationError("invalid_proposal", 422)
		}
	}
	operation, err := uuid.Parse(p.OperationID)
	if err != nil {
		return integrationError("invalid_operation_id", 422)
	}
	p.OperationID = operation.String()
	p.StickerID = strings.TrimSpace(p.StickerID)
	p.PostType = strings.TrimSpace(p.PostType)
	p.Content = strings.TrimSpace(p.Content)
	p.Title = strings.TrimSpace(p.Title)
	if strings.ContainsRune(p.Content, 0) || strings.ContainsRune(p.Title, 0) {
		return integrationError("invalid_content", 422)
	}
	if len(p.ImageFileIDs) > 3 || len(p.Sources) > 3 {
		return integrationError("invalid_proposal", 422)
	}
	seen := map[uint]bool{}
	for _, id := range p.ImageFileIDs {
		if id == 0 || seen[id] {
			return integrationError("invalid_proposal", 422)
		}
		seen[id] = true
	}
	seen = map[uint]bool{}
	for _, source := range p.Sources {
		if source.PostID == 0 || len(source.Version) != 64 || seen[source.PostID] {
			return integrationError("invalid_proposal", 422)
		}
		seen[source.PostID] = true
	}
	// Multiple owners may reference the same posts; acquire source locks in one order.
	sort.Slice(p.Sources, func(i, j int) bool { return p.Sources[i].PostID < p.Sources[j].PostID })
	switch p.Kind {
	case "post":
		if p.PostID != 0 || p.SourceVersion != "" || p.ReplyToReplyID != 0 || p.ReplySourceVersion != "" || p.StickerID != "" || p.PostType == "" || len(p.PostType) > 64 || p.Content == "" || utf8.RuneCountInString(p.Content) > 9900 || utf8.RuneCountInString(p.Title) > 120 {
			return integrationError("invalid_proposal", 422)
		}
	case "reply":
		if len(p.ImageFileIDs) != 0 || len(p.Sources) != 0 {
			return integrationError("invalid_proposal", 422)
		}
		if p.PostType != "" || p.Title != "" || p.PostID == 0 || len(p.SourceVersion) != 64 || utf8.RuneCountInString(p.Content) > 4900 || (p.Content == "" && p.StickerID == "") || (p.ReplyToReplyID > 0 && len(p.ReplySourceVersion) != 64) || (p.ReplyToReplyID == 0 && p.ReplySourceVersion != "") {
			return integrationError("invalid_proposal", 422)
		}
		if p.StickerID != "" && (s.ValidSticker == nil || !s.ValidSticker(p.StickerID)) {
			return integrationError("invalid_sticker", 422)
		}
	default:
		return integrationError("unsupported_action", 422)
	}
	return nil
}
func (s *IntegrationActionService) activeBinding(tx *gorm.DB, user models.User, id string, epoch uint) (models.IntegrationBinding, error) {
	var binding models.IntegrationBinding
	if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Where("id = ? AND owner_id = ?", id, user.ID).Take(&binding).Error; err != nil {
		return binding, err
	}
	if binding.Epoch != epoch || !IntegrationHasScope(binding, IntegrationProposeScope) {
		return binding, integrationError("authorization_changed", 403)
	}
	return binding, s.Auth.bindingValid(tx, binding, user)
}
func (s *IntegrationActionService) Propose(ctx context.Context, b models.IntegrationBinding, p IntegrationProposal) (models.IntegrationAction, error) {
	var action models.IntegrationAction
	if err := s.normalize(&p); err != nil {
		return action, err
	}
	raw, _ := json.Marshal(p)
	hash := IntegrationSecretHash(string(raw))
	err := s.Auth.ownerTx(ctx, b.OwnerID, func(tx *gorm.DB, user models.User) error {
		if _, err := s.activeBinding(tx, user, b.ID, b.Epoch); err != nil {
			return err
		}
		err := tx.Where("binding_id = ? AND operation_id = ?", b.ID, p.OperationID).Take(&action).Error
		if err == nil {
			if action.RequestHash != hash {
				return integrationError("operation_conflict", 409)
			}
			if action.State == "pending" {
				_, _, err = s.checkSource(tx, p)
				return err
			}
			return nil
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if _, _, err := s.checkSource(tx, p); err != nil {
			return err
		}
		if p.Kind == "post" {
			if _, err := s.section(tx, user.ID, p.PostType); err != nil {
				return err
			}
		}
		var count int64
		if err := tx.Model(&models.IntegrationAction{}).Where("owner_id = ? AND created_at > ?", user.ID, s.Auth.Now().Add(-24*time.Hour)).Count(&count).Error; err != nil {
			return err
		}
		if count >= 30 {
			return integrationError("proposal_quota_exceeded", 429)
		}
		action = models.IntegrationAction{ID: uuid.NewString(), OwnerID: user.ID, BindingID: b.ID, BindingEpoch: b.Epoch, OperationID: p.OperationID, RequestHash: hash, Kind: p.Kind, State: "pending", Version: 1, Payload: raw, PayloadHash: hash, CreatedAt: s.Auth.Now(), ExpiresAt: s.Auth.Now().Add(72 * time.Hour)}
		if err := tx.Create(&action).Error; err != nil {
			return err
		}
		return tx.Create(&models.IntegrationAudit{OwnerID: user.ID, BindingID: b.ID, ActionID: action.ID, Event: "draft_created", CreatedAt: s.Auth.Now()}).Error
	})
	return action, err
}
func (s *IntegrationActionService) section(tx *gorm.DB, owner uint, slug string) (models.WaterSection, error) {
	var section models.WaterSection
	if err := tx.Clauses(clause.Locking{Strength: "SHARE"}).Where("slug = ? AND status = ?", slug, "active").Take(&section).Error; err != nil {
		return section, integrationError("section_unavailable", 409)
	}
	var count int64
	if err := tx.Model(&models.WaterSectionMute{}).Where("section_id = ? AND user_id = ? AND status = ? AND (until IS NULL OR until >= ?)", section.ID, owner, models.MuteStatusActive, s.Auth.Now()).Count(&count).Error; err != nil {
		return section, err
	}
	if count > 0 {
		return section, integrationError("section_muted", 403)
	}
	return section, nil
}
func (s *IntegrationActionService) load(tx *gorm.DB, owner uint, id string) (models.IntegrationAction, IntegrationProposal, error) {
	var a models.IntegrationAction
	var p IntegrationProposal
	if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Where("id = ? AND owner_id = ?", id, owner).Take(&a).Error; err != nil {
		return a, p, err
	}
	if err := json.Unmarshal(a.Payload, &p); err != nil {
		return a, p, err
	}
	return a, p, nil
}
func (s *IntegrationActionService) Preview(ctx context.Context, owner uint, id string, pluginBinding *models.IntegrationBinding) (IntegrationActionPreview, error) {
	var result IntegrationActionPreview
	err := s.Auth.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		a, p, err := s.load(tx, owner, id)
		if err != nil {
			return err
		}
		if pluginBinding != nil && a.BindingID != pluginBinding.ID {
			return gorm.ErrRecordNotFound
		}
		if _, err = s.activeBinding(tx, user, a.BindingID, a.BindingEpoch); err != nil {
			return err
		}
		if a.State == "pending" {
			if !a.ExpiresAt.After(s.Auth.Now()) {
				return integrationError("draft_expired", 409)
			}
			if _, _, err = s.checkSource(tx, p); err != nil {
				return err
			}
			if pluginBinding == nil {
				nonce, err := integrationSecret("ac_")
				if err != nil {
					return err
				}
				expiry := s.Auth.Now().Add(5 * time.Minute)
				if err := tx.Model(&a).Updates(map[string]interface{}{"confirm_nonce_hash": IntegrationSecretHash(nonce), "confirm_expires_at": expiry}).Error; err != nil {
					return err
				}
				result.Nonce = nonce
				result.ConfirmationExpiresAt = &expiry
			}
		} else {
			a.Payload = []byte(`{}`)
		}
		result.Action = a
		return nil
	})
	return result, err
}
func (s *IntegrationActionService) Decide(ctx context.Context, owner uint, id string, d IntegrationActionDecision) (models.IntegrationAction, error) {
	return s.decide(ctx, owner, id, d, nil)
}
func (s *IntegrationActionService) decide(ctx context.Context, owner uint, id string, d IntegrationActionDecision, automatic *models.IntegrationBinding) (models.IntegrationAction, error) {
	var result models.IntegrationAction
	var notification *models.Notification
	err := s.Auth.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		a, p, err := s.load(tx, owner, id)
		if err != nil {
			return err
		}
		if automatic != nil {
			current, err := s.activeBinding(tx, user, automatic.ID, automatic.Epoch)
			if err != nil {
				return err
			}
			required := IntegrationAutoReplyScope
			if a.Kind == "post" {
				required = IntegrationAutoPostScope
			}
			if a.BindingID != current.ID || a.BindingEpoch != current.Epoch || (a.Kind != "reply" && a.Kind != "post") || !IntegrationHasScope(current, required) {
				return integrationError("insufficient_scope", 403)
			}
		}
		if automatic == nil && (len(p.ImageFileIDs) > 0 || len(p.Sources) > 0 || p.RuntimeSessionID != "" || p.BotRevision != 0) {
			return integrationError("bot_publication_requires_bot_route", 403)
		}
		if a.Version != d.Version || a.PayloadHash != d.PayloadHash {
			return integrationError("draft_changed", 409)
		}
		if a.State == "published" || a.State == "rejected" {
			a.Payload = []byte(`{}`)
			result = a
			return nil
		}
		if _, err = s.activeBinding(tx, user, a.BindingID, a.BindingEpoch); err != nil {
			return err
		}
		if a.State != "pending" || !a.ExpiresAt.After(s.Auth.Now()) {
			return integrationError("draft_expired", 409)
		}
		if automatic == nil && (d.Nonce == "" || IntegrationSecretHash(d.Nonce) != a.ConfirmNonceHash || a.ConfirmExpiresAt == nil || !a.ConfirmExpiresAt.After(s.Auth.Now())) {
			return integrationError("confirmation_expired", 409)
		}
		now := s.Auth.Now()
		if !d.Allow {
			a.State = "rejected"
		} else {
			if _, err := s.eligibleCommunityRules(tx, user); err != nil {
				return err
			}
			post, target, err := s.checkSource(tx, p)
			if err != nil {
				return err
			}
			slug := p.PostType
			if p.Kind == "reply" {
				slug = post.PostType
			}
			if _, err = s.section(tx, owner, slug); err != nil {
				return err
			}
			var daily int64
			if err := tx.Model(&models.IntegrationAction{}).Where("owner_id = ? AND state = ? AND completed_at > ?", owner, "published", now.Add(-24*time.Hour)).Count(&daily).Error; err != nil {
				return err
			}
			if daily >= 20 {
				return integrationError("assistant_publish_quota_exceeded", 429)
			}
			text := "[助手代发] " + p.Content
			actor := owner
			if automatic != nil {
				if err := s.checkBotRuntime(tx, *automatic, p, now); err != nil {
					return err
				}
				if p.Kind == "post" {
					actor, err = s.botPostActor(tx, owner, now, p)
				} else {
					actor, err = s.botActor(tx, owner, now, post, p)
				}
				if err != nil {
					return err
				}
				text = "[AI机器人] " + p.Content
			}
			if p.Kind == "post" {
				created := models.Post{AuthorID: actor, Title: p.Title, Content: text, BoardID: models.BoardShuitie, PostType: p.PostType, ContentKind: models.PostContentKindNormal, Status: models.PostStatusNormal, ContentOrigin: "assistant"}
				if err := PreparePostPublish(tx, &created, now); err != nil {
					return err
				}
				// 自动帖子只用机器人自己上传/获授的图片，即使他人的图片公开也不能偷用。
				if automatic != nil {
					if err := s.checkBotImages(tx, actor, p.ImageFileIDs); err != nil {
						return err
					}
				}
				if _, err := ValidateImageFileIDs(tx, p.ImageFileIDs, 3, actor); err != nil {
					return integrationError("invalid_image_reference", 422)
				}
				if err := ClaimPublicImageFiles(tx, p.ImageFileIDs); err != nil {
					return err
				}
				if err := tx.Create(&created).Error; err != nil {
					return err
				}
				for i, fileID := range p.ImageFileIDs {
					if err := tx.Create(&models.PostImage{PostID: created.ID, FileID: fileID, SortOrder: i}).Error; err != nil {
						return err
					}
				}
				a.PostID = &created.ID
			} else {
				reply := models.Reply{AuthorID: actor, PostID: post.ID, Content: text, Status: models.ReplyStatusNormal, ContentOrigin: "assistant"}
				if p.StickerID != "" {
					if s.ValidSticker == nil || !s.ValidSticker(p.StickerID) {
						return integrationError("invalid_sticker", 409)
					}
					reply.StickerID = &p.StickerID
					if p.Content == "" {
						reply.Content = "[助手代发表情]"
						if automatic != nil {
							reply.Content = "[AI机器人表情]"
						}
					}
				}
				if target != nil {
					root := target.ID
					if target.ParentReplyID != nil {
						root = *target.ParentReplyID
					}
					reply.ParentReplyID = &root
					reply.ReplyToReplyID = &target.ID
					reply.ReplyToUserID = &target.AuthorID
				}
				if err := PrepareReplyPublish(tx, &reply, func() string {
					if p.Content == "" {
						return ""
					}
					return text
				}(), now); err != nil {
					return err
				}
				if err := InsertReplyWithActivity(tx, &reply); err != nil {
					return err
				}
				recipient := post.AuthorID
				if reply.ReplyToUserID != nil {
					recipient = *reply.ReplyToUserID
				}
				notification, err = CreateReplyNotification(tx, recipient, actor, reply.ID, post.ID, reply.Content)
				if err != nil {
					return err
				}
				a.PostID = &post.ID
				a.ReplyID = &reply.ID
			}
			a.State = "published"
		}
		a.CompletedAt = &now
		a.ConfirmNonceHash = ""
		a.ConfirmExpiresAt = nil
		a.Payload = []byte(`{}`)
		if err := tx.Save(&a).Error; err != nil {
			return err
		}
		if err := tx.Create(&models.IntegrationAudit{OwnerID: owner, BindingID: a.BindingID, ActionID: a.ID, Event: a.State, CreatedAt: now}).Error; err != nil {
			return err
		}
		a.Payload = []byte(`{}`)
		result = a
		return nil
	})
	if err == nil && notification != nil && s.AfterReplyCommit != nil {
		s.AfterReplyCommit(*notification)
	}
	return result, err
}
func (s *IntegrationActionService) eligibleCommunityRules(tx *gorm.DB, user models.User) (bool, error) {
	var n int64
	if err := tx.Model(&models.UserLegalConsent{}).Where("user_id = ? AND document = ? AND version = ? AND revoked_at IS NULL AND acknowledgement_type = ?", user.ID, models.LegalDocumentCommunityRules, models.LegalDocumentVersion, "rules_acceptance").Count(&n).Error; err != nil {
		return false, err
	}
	if n == 0 {
		return false, integrationError("community_rules_required", 403)
	}
	return true, nil
}
