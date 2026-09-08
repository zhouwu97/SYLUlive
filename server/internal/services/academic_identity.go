package services

import (
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

// VerifiedAcademicIdentities 是身份列表和本人资料共用的事实来源，不拼接旧授权字段。
func VerifiedAcademicIdentities(db *gorm.DB, userID uint) ([]models.AcademicIdentityBinding, error) {
	bindings := make([]models.AcademicIdentityBinding, 0)
	err := db.Where("user_id = ?", userID).Order("provider_id DESC, student_id ASC").Find(&bindings).Error
	return bindings, err
}

// AcademicLoginAvailable 无 Provider 的学号登录必须唯一对应一个 App 用户。
func AcademicLoginAvailable(db *gorm.DB, bindings []models.AcademicIdentityBinding) (bool, error) {
	for _, binding := range bindings {
		var owners int64
		if err := db.Model(&models.AcademicIdentityBinding{}).Where("student_id = ?", binding.StudentID).Distinct("user_id").Count(&owners).Error; err != nil {
			return false, err
		}
		if owners == 1 {
			return true, nil
		}
	}
	return false, nil
}

// MigrateAcademicIdentities 在启动时回填旧认证；唯一键保证已有 Provider 事实优先。
func MigrateAcademicIdentities(db *gorm.DB) error {
	var users []models.User
	if err := db.Select("id", "student_id", "student_verified_at", "academic_provider_id").Where("student_verified_at IS NOT NULL AND student_id <> ''").Find(&users).Error; err != nil {
		return err
	}
	return db.Transaction(func(tx *gorm.DB) error {
		for _, user := range users {
			provider := string(user.AcademicProviderID)
			if provider == "" {
				provider = models.AcademicProviderUndergraduate
			}
			if _, err := models.ParseAcademicProviderID(provider); err != nil {
				return err
			}
			binding := models.AcademicIdentityBinding{UserID: user.ID, ProviderID: provider, StudentID: user.StudentID, VerifiedAt: *user.StudentVerifiedAt, VerificationMethod: "legacy_migration", VerificationVersion: "v1"}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&binding).Error; err != nil {
				return err
			}
			// 消费旧认证标记，防止后续解绑后又在下次启动时回填出旧身份。
			// 已验证状态此后只从 binding 读取，旧学号列仅保留给存量清理任务。
			if err := tx.Model(&models.User{}).Where("id = ?", user.ID).Update("student_verified_at", nil).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

// SeedAcademicAccountConfigs 仅为历史身份补首次云端配置；已有配置和删除墓碑始终优先。
func SeedAcademicAccountConfigs(db *gorm.DB) error {
	var bindings []models.AcademicIdentityBinding
	if err := db.Where("user_id IN (?)", db.Model(&models.User{}).Select("id").Where("account_status = ? OR account_status = ?", "active", "")).Find(&bindings).Error; err != nil {
		return err
	}
	return db.Transaction(func(tx *gorm.DB) error {
		for _, binding := range bindings {
			config := models.AcademicAccountConfig{UserID: binding.UserID, ProviderID: binding.ProviderID,
				StudentID: binding.StudentID, State: "active", Revision: 1}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&config).Error; err != nil {
				return err
			}
		}
		return nil
	})
}
