package services

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"
)

var ErrEmojiCreatorRequired = errors.New("请先申请并开通表情创作者权限；本机导入自用不受影响")

func (s *EmojiPackService) RequireCreator(ctx context.Context, userID uint) error {
	return requireEmojiCreator(s.DB.WithContext(ctx), userID, false)
}

func requireEmojiCreator(tx *gorm.DB, userID uint, lock bool) error {
	var user models.User
	users := tx.Select("id", "account_status")
	if lock {
		users = users.Clauses(clause.Locking{Strength: "SHARE"})
	}
	if err := users.First(&user, userID).Error; err != nil {
		return err
	}
	if user.AccountStatus != "active" && user.AccountStatus != "" {
		return ErrEmojiCreatorRequired
	}
	var creator models.EmojiCreator
	query := tx
	if lock {
		query = query.Clauses(clause.Locking{Strength: "SHARE"})
	}
	err := query.First(&creator, "user_id = ?", userID).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return ErrEmojiCreatorRequired
	}
	if err != nil {
		return err
	}
	if creator.Status != models.EmojiCreatorActive {
		return ErrEmojiCreatorRequired
	}
	return nil
}

func (s *EmojiPackService) ApplyCreator(ctx context.Context, userID uint, description string, version int) (*models.EmojiCreator, error) {
	description = strings.TrimSpace(description)
	if description == "" || len(description) > 6000 || utils.CountGraphemes(description) > 300 {
		return nil, ErrEmojiPackInvalid
	}
	var creator models.EmojiCreator
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.AccountStatus != "active" && user.AccountStatus != "" {
			return ErrEmojiPackForbidden
		}
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&creator, "user_id = ?", userID).Error
		if errors.Is(err, gorm.ErrRecordNotFound) {
			if version != 0 {
				return ErrEmojiPackConflict
			}
			creator = models.EmojiCreator{UserID: userID, Description: description, Status: models.EmojiCreatorPending, Version: 1}
			return tx.Create(&creator).Error
		}
		if err != nil {
			return err
		}
		if creator.Status == models.EmojiCreatorPending && creator.Description == description {
			return nil
		}
		if creator.Version != version || (creator.Status != models.EmojiCreatorRejected && creator.Status != models.EmojiCreatorSuspended) {
			return ErrEmojiPackConflict
		}
		creator.Description, creator.Status = description, models.EmojiCreatorPending
		creator.Version++
		creator.ReviewReason, creator.ReviewedBy, creator.ReviewedAt = "", nil, nil
		return tx.Save(&creator).Error
	})
	return &creator, err
}

func (s *EmojiPackService) ReviewCreator(ctx context.Context, userID, adminID uint, version int, action, reason string) error {
	reason = strings.TrimSpace(reason)
	if userID == 0 || version < 1 || utf8.RuneCountInString(reason) > 500 || utils.CountGraphemes(reason) > 300 || (action != "approve" && action != "reject" && action != "suspend") || (action != "approve" && reason == "") {
		return ErrEmojiPackInvalid
	}
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var admin models.User
		if err := tx.Clauses(clause.Locking{Strength: "SHARE"}).First(&admin, adminID).Error; err != nil {
			return err
		}
		if (admin.AccountStatus != "active" && admin.AccountStatus != "") || (admin.Role != "admin" && admin.Role != "super_admin") || adminID == userID {
			return ErrEmojiPackForbidden
		}
		var creator models.EmojiCreator
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&creator, "user_id = ?", userID).Error; err != nil {
			return err
		}
		expected, next := models.EmojiCreatorPending, models.EmojiCreatorActive
		if action == "reject" {
			next = models.EmojiCreatorRejected
		}
		if action == "suspend" {
			expected, next = models.EmojiCreatorActive, models.EmojiCreatorSuspended
		}
		if creator.Status != expected || creator.Version != version {
			return ErrEmojiPackConflict
		}
		now := time.Now()
		result := tx.Model(&models.EmojiCreator{}).Where("user_id = ? AND version = ? AND status = ?", userID, version, expected).Updates(map[string]any{"status": next, "version": version + 1, "review_reason": reason, "reviewed_by": adminID, "reviewed_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrEmojiPackConflict
		}
		return tx.Create(&models.AdminLog{AdminID: adminID, AdminName: admin.Nickname, Action: map[string]string{"approve": "开通表情创作者", "reject": "驳回表情创作者申请", "suspend": "暂停表情创作者"}[action], Target: strconv.FormatUint(uint64(userID), 10), Detail: reason}).Error
	})
}
