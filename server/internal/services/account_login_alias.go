package services

import (
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	"time"
)

const accountLoginAliasMigration = "20260908_01_fixed_legacy_login_aliases"

// MigrateAccountLoginAliases 只快照一次既有登录身份，后续换绑不得新增或替换登录名。
func MigrateAccountLoginAliases(db *gorm.DB) error {
	if err := db.AutoMigrate(&models.AccountLoginAlias{}, &models.AppSchemaMigration{}); err != nil {
		return err
	}
	return db.Transaction(func(tx *gorm.DB) error {
		var applied int64
		if err := tx.Model(&models.AppSchemaMigration{}).Where("version = ?", accountLoginAliasMigration).Count(&applied).Error; err != nil {
			return err
		}
		if applied > 0 {
			return nil
		}
		var bindings []models.AcademicIdentityBinding
		if err := tx.Where("user_id IN (?)", tx.Model(&models.User{}).Select("id").Where("account_status = ?", "active")).Order("created_at ASC, id ASC").Find(&bindings).Error; err != nil {
			return err
		}
		for _, binding := range bindings {
			alias := models.AccountLoginAlias{UserID: binding.UserID, Value: binding.StudentID, Source: "legacy_binding_snapshot", CreatedAt: binding.CreatedAt}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&alias).Error; err != nil {
				return err
			}
		}
		return tx.Create(&models.AppSchemaMigration{Version: accountLoginAliasMigration, AppliedAt: time.Now()}).Error
	})
}

// AvailableAccountLoginAliases 只返回唯一对应当前有效账号的历史登录名。
func AvailableAccountLoginAliases(db *gorm.DB, userID uint) ([]models.AccountLoginAlias, error) {
	aliases := make([]models.AccountLoginAlias, 0)
	err := db.Where("user_id = ?", userID).Where(`value IN (
		SELECT a.value FROM account_login_aliases a JOIN users u ON u.id = a.user_id
		WHERE u.account_status = 'active' GROUP BY a.value HAVING COUNT(DISTINCT a.user_id) = 1
	)`).Order("created_at ASC, id ASC").Find(&aliases).Error
	return aliases, err
}
