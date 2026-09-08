package services

import (
	"context"
	"errors"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	"time"
)

type AcademicRetirementReport struct {
	LegacyUsers    int64 `json:"legacy_users"`
	SecretRows     int64 `json:"secret_rows"`
	PendingCleanup int64 `json:"pending_cleanup"`
}

// InventoryAcademicRetirement 只返回计数，不导出学号、密码或 Cookie。
func InventoryAcademicRetirement(ctx context.Context, db *gorm.DB) (AcademicRetirementReport, error) {
	var report AcademicRetirementReport
	if err := db.WithContext(ctx).Model(&models.User{}).Where("edu_authorized = ? OR edu_bound = ? OR (edu_student_id <> '' AND edu_session_state <> 'revoked')", true, true).Count(&report.LegacyUsers).Error; err != nil {
		return report, err
	}
	if err := db.WithContext(ctx).Model(&models.User{}).Where("COALESCE(edu_password, '') <> '' OR COALESCE(edu_cookie, '') <> ''").Count(&report.SecretRows).Error; err != nil {
		return report, err
	}
	err := db.WithContext(ctx).Model(&models.EduCredentialCleanupJob{}).Where("completed_at IS NULL").Count(&report.PendingCleanup).Error
	return report, err
}

// PrepareAcademicRetirement 仅在已冻结入口且客户端验收通过后撤销旧授权。
// Python/Redis 副本通过已有 outbox 清理；未清空 pending 前不能关闭该 worker 或 DROP 字段。
func PrepareAcademicRetirement(ctx context.Context, db *gorm.DB, frozen, clientsAccepted bool, minVersion int64) error {
	if !frozen || !clientsAccepted || minVersion <= 0 {
		return errors.New("必须先冻结旧入口、完成客户端验收并确定最低版本")
	}
	now := time.Now().UTC()
	cleanup := NewEduCredentialCleanupJobService(db, nil, time.Now)
	return db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var users []models.User
		// 只读取身份代次和旧绑定标记，避免把秘密列载入内存。
		if err := tx.Select("id", "edu_authorization_generation").Clauses(clause.Locking{Strength: "UPDATE"}).Where("edu_authorized = ? OR edu_bound = ? OR (edu_student_id <> '' AND edu_session_state <> 'revoked') OR COALESCE(edu_password, '') <> '' OR COALESCE(edu_cookie, '') <> ''", true, true).Find(&users).Error; err != nil {
			return err
		}
		for _, user := range users {
			if err := cleanup.Enqueue(tx, user.ID, user.EduAuthorizationGeneration, now, false); err != nil {
				return err
			}
			if err := tx.Model(&models.User{}).Where("id = ?", user.ID).Updates(map[string]interface{}{
				"edu_authorized": false, "edu_bound": false, "edu_auto_relogin": false,
				"edu_password": "", "edu_cookie": "", "edu_session_state": "revoked",
				"edu_cleanup_pending": true, "edu_binding_state": "cleanup_pending",
			}).Error; err != nil {
				return err
			}
		}
		return nil
	})
}
