package services

import (
	"errors"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

var ErrCanteenArchiveSuperAdminRequired = errors.New("canteen_archive_super_admin_required")

// RequireCanteenArchiveWrite 与上下架共用食堂行锁，避免检查营业状态后发生下架竞态。
// 管理端和举报治理共用此检查，普通管理员不能改动怀旧存档。
func RequireCanteenArchiveWrite(tx *gorm.DB, canteenID, actorID uint) error {
	var canteen models.Canteen
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&canteen, canteenID).Error; err != nil {
		return err
	}
	if canteen.OperatingStatus != models.CanteenOperatingOffline {
		return nil
	}
	var actor models.User
	if err := tx.Select("id", "role", "account_status").First(&actor, actorID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrCanteenArchiveSuperAdminRequired
		}
		return err
	}
	if actor.Role != models.RoleSuperAdmin || actor.AccountStatus != "active" {
		return ErrCanteenArchiveSuperAdminRequired
	}
	return nil
}
