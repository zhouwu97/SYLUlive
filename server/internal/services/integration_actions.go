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
	"strings"
	"time"
	"unicode/utf8"
)

type IntegrationProposal struct {
	OperationID        string `json:"operation_id"`
	Kind               string `json:"kind"`
	Title              string `json:"title,omitempty"`
	Content            string `json:"content"`
	PostType           string `json:"post_type,omitempty"`
	PostID             uint   `json:"post_id,omitempty"`
	SourceVersion      string `json:"source_version,omitempty"`
	ReplyToReplyID     uint   `json:"reply_to_reply_id,omitempty"`
	ReplySourceVersion string `json:"reply_source_version,omitempty"`
	StickerID          string `json:"sticker_id,omitempty"`
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
	switch p.Kind {
	case "post":
		if p.PostID != 0 || p.SourceVersion != "" || p.ReplyToReplyID != 0 || p.ReplySourceVersion != "" || p.StickerID != "" || p.PostType == "" || len(p.PostType) > 64 || p.Content == "" || utf8.RuneCountInString(p.Content) > 9900 || utf8.RuneCountInString(p.Title) > 120 {
			return integrationError("invalid_proposal", 422)
		}
	case "reply":
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
	var result models.IntegrationAction
	var notification *models.Notification
	err := s.Auth.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		a, p, err := s.load(tx, owner, id)
		if err != nil {
			return err
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
		if d.Nonce == "" || IntegrationSecretHash(d.Nonce) != a.ConfirmNonceHash || a.ConfirmExpiresAt == nil || !a.ConfirmExpiresAt.After(s.Auth.Now()) {
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
			if p.Kind == "post" {
				created := models.Post{AuthorID: owner, Title: p.Title, Content: text, BoardID: models.BoardShuitie, PostType: p.PostType, ContentKind: models.PostContentKindNormal, Status: models.PostStatusNormal, ContentOrigin: "assistant"}
				if err := PreparePostPublish(tx, &created, now); err != nil {
					return err
				}
				if err := tx.Create(&created).Error; err != nil {
					return err
				}
				a.PostID = &created.ID
			} else {
				reply := models.Reply{AuthorID: owner, PostID: post.ID, Content: text, Status: models.ReplyStatusNormal, ContentOrigin: "assistant"}
				if p.StickerID != "" {
					if s.ValidSticker == nil || !s.ValidSticker(p.StickerID) {
						return integrationError("invalid_sticker", 409)
					}
					reply.StickerID = &p.StickerID
					if p.Content == "" {
						reply.Content = "[助手代发表情]"
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
				notification, err = CreateReplyNotification(tx, recipient, owner, reply.ID, post.ID, reply.Content)
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
