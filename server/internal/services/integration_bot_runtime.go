package services

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

const BotRuntimeLease = 2 * time.Minute

type BotRuntimeHeartbeat struct {
	SessionID        string `json:"session_id"`
	Sequence         uint64 `json:"sequence"`
	Revision         uint64 `json:"revision"`
	State            string `json:"state"`
	ErrorCode        string `json:"error_code"`
	RoundID          string `json:"round_id"`
	ReadCount        int    `json:"read_count"`
	NextRunInSeconds int    `json:"next_run_in_seconds"`
}

// Only operational metadata is retained; credentials and model/community text never enter this record.
type botRuntimeRecord struct {
	BindingID    string     `json:"binding_id"`
	BindingEpoch uint       `json:"binding_epoch"`
	SessionID    string     `json:"session_id"`
	Sequence     uint64     `json:"sequence"`
	Revision     uint64     `json:"revision"`
	State        string     `json:"state"`
	ErrorCode    string     `json:"error_code,omitempty"`
	RoundID      string     `json:"round_id,omitempty"`
	LastSeenAt   time.Time  `json:"last_seen_at"`
	LastReadAt   *time.Time `json:"last_read_at,omitempty"`
	NextRunAt    *time.Time `json:"next_run_at,omitempty"`
}

type BotRuntimeStatus struct {
	State      string            `json:"state"`
	ErrorCode  string            `json:"error_code,omitempty"`
	LastSeenAt *time.Time        `json:"last_seen_at,omitempty"`
	LastReadAt *time.Time        `json:"last_read_at,omitempty"`
	NextRunAt  *time.Time        `json:"next_run_at,omitempty"`
	LastAction *BotRuntimeAction `json:"last_action,omitempty"`
}

type BotRuntimeAction struct {
	Kind        string     `json:"kind"`
	PostID      *uint      `json:"post_id,omitempty"`
	ReplyID     *uint      `json:"reply_id,omitempty"`
	CompletedAt *time.Time `json:"completed_at"`
}

func parseBotRuntime(bot models.ManagedBot) botRuntimeRecord {
	var record botRuntimeRecord
	_ = json.Unmarshal([]byte(bot.RuntimeJSON), &record)
	return record
}

func (s *IntegrationActionService) RecordBotRuntime(ctx context.Context, expected models.IntegrationBinding, report BotRuntimeHeartbeat) error {
	states := map[string]bool{"idle": true, "waiting": true, "loading": true, "completed": true, "empty": true, "error": true, "paused": true, "disabled": true, "scope_required": true, "cooldown": true, "stopped": true}
	errorsAllowed := map[string]bool{"": true, "public_browse_failed": true, "network_unavailable": true, "service_unavailable": true, "provider_required": true, "authorization_required": true}
	if _, err := uuid.Parse(report.SessionID); err != nil || report.Sequence == 0 || report.Revision == 0 || !states[report.State] || !errorsAllowed[report.ErrorCode] || report.ReadCount < 0 || report.ReadCount > 5 || report.NextRunInSeconds < 0 || report.NextRunInSeconds > 86400 {
		return integrationError("invalid_bot_runtime", 422)
	}
	if report.RoundID != "" {
		if _, err := uuid.Parse(report.RoundID); err != nil {
			return integrationError("invalid_bot_runtime", 422)
		}
	}
	return s.Auth.ownerTx(ctx, expected.OwnerID, func(tx *gorm.DB, user models.User) error {
		var binding models.IntegrationBinding
		if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).Where("id = ? AND owner_id = ?", expected.ID, user.ID).Take(&binding).Error; err != nil {
			return err
		}
		if binding.Epoch != expected.Epoch {
			return integrationError("authorization_changed", 403)
		}
		if err := s.Auth.bindingValid(tx, binding, user); err != nil {
			return err
		}
		if !IntegrationHasScope(binding, IntegrationReadScope) {
			return integrationError("insufficient_scope", 403)
		}
		var bot models.ManagedBot
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&bot, "owner_id = ?", binding.OwnerID).Error; err != nil {
			return err
		}
		if bot.Revision != report.Revision {
			return integrationError("bot_policy_changed", 409)
		}
		now := s.Auth.Now()
		previous := parseBotRuntime(bot)
		sameBinding := previous.BindingID == binding.ID && previous.BindingEpoch == binding.Epoch
		if sameBinding && previous.SessionID != "" && previous.SessionID != report.SessionID && previous.LastSeenAt.Add(BotRuntimeLease).After(now) {
			return integrationError("bot_runtime_busy", 409)
		}
		if sameBinding && previous.SessionID == report.SessionID && previous.Sequence >= report.Sequence {
			return integrationError("stale_bot_runtime", 409)
		}
		lastRead := previous.LastReadAt
		if report.RoundID != "" && report.RoundID != previous.RoundID && report.State == "completed" && report.ReadCount > 0 {
			lastRead = &now
		}
		next := now.Add(time.Duration(report.NextRunInSeconds) * time.Second)
		record := botRuntimeRecord{BindingID: binding.ID, BindingEpoch: binding.Epoch, SessionID: report.SessionID, Sequence: report.Sequence, Revision: report.Revision, State: report.State, ErrorCode: report.ErrorCode, RoundID: report.RoundID, LastSeenAt: now, LastReadAt: lastRead, NextRunAt: &next}
		if report.State == "stopped" {
			record.SessionID, record.NextRunAt = "", nil
		}
		raw, err := json.Marshal(record)
		if err != nil {
			return err
		}
		return tx.Model(&bot).Update("runtime_json", string(raw)).Error
	})
}

// This runs in the existing publication transaction, after owner/binding/source locks and before bot writes.
func (s *IntegrationActionService) checkBotRuntime(tx *gorm.DB, binding models.IntegrationBinding, p IntegrationProposal, now time.Time) error {
	var bot models.ManagedBot
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&bot, "owner_id = ?", binding.OwnerID).Error; err != nil {
		return err
	}
	// Legacy installations remain compatible until this bot has joined the runtime protocol.
	if bot.RuntimeJSON == "" && p.RuntimeSessionID == "" {
		return nil
	}
	current := parseBotRuntime(bot)
	if p.RuntimeSessionID == "" || p.RuntimeSessionID != current.SessionID || binding.ID != current.BindingID || binding.Epoch != current.BindingEpoch || !current.LastSeenAt.Add(BotRuntimeLease).After(now) || current.State != "loading" {
		return integrationError("bot_runtime_required", 409)
	}
	if p.BotRevision != bot.Revision || current.Revision != bot.Revision {
		return integrationError("bot_policy_changed", 409)
	}
	return nil
}

func (s *IntegrationActionService) BotRuntimeStatus(ctx context.Context, owner uint) (BotRuntimeStatus, error) {
	status := BotRuntimeStatus{State: "not_created"}
	db := s.Auth.DB.WithContext(ctx)
	var bot models.ManagedBot
	if err := db.First(&bot, "owner_id = ?", owner).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return status, nil
		}
		return status, err
	}
	record := parseBotRuntime(bot)
	status.LastReadAt = record.LastReadAt
	var latest BotRuntimeAction
	posts := db.Unscoped().Model(&models.Post{}).Select("id").Where("author_id = ?", bot.UserID)
	replies := db.Unscoped().Model(&models.Reply{}).Select("id").Where("author_id = ?", bot.UserID)
	result := db.Model(&models.IntegrationAction{}).Select("kind", "post_id", "reply_id", "completed_at").Where("owner_id = ? AND state = ?", owner, "published").Where("(kind = 'post' AND post_id IN (?)) OR (kind = 'reply' AND reply_id IN (?))", posts, replies).Order("completed_at DESC").Limit(1).Scan(&latest)
	if result.Error != nil {
		return status, result.Error
	}
	if latest.CompletedAt != nil {
		status.LastAction = &latest
	}
	if !bot.Enabled {
		status.State = "paused"
		return status, nil
	}
	if policy := ManagedBotPolicy(bot); !policy.PublicReadEnabled || len(policy.AllowedPostTypes) == 0 {
		status.State = "read_disabled"
		return status, nil
	}
	var binding models.IntegrationBinding
	err := db.Where("owner_id = ? AND state = ?", owner, "active").Take(&binding).Error
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return status, err
	}
	if err != nil || !IntegrationHasScope(binding, IntegrationReadScope) || s.Auth.CheckBinding(ctx, binding) != nil {
		status.State = "scope_required"
		return status, nil
	}
	status.State = "offline"
	if record.BindingID != binding.ID || record.BindingEpoch != binding.Epoch {
		return status, nil
	}
	if !record.LastSeenAt.IsZero() {
		status.LastSeenAt = &record.LastSeenAt
	}
	if record.SessionID == "" || !record.LastSeenAt.Add(BotRuntimeLease).After(s.Auth.Now()) {
		return status, nil
	}
	if record.Revision != bot.Revision {
		status.State = "syncing"
		return status, nil
	}
	status.State, status.ErrorCode, status.NextRunAt = record.State, record.ErrorCode, record.NextRunAt
	return status, nil
}
