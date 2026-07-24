package models

import (
	"fmt"
	"regexp"
	"time"

	"gorm.io/gorm"
)

var studentIdentityPattern = regexp.MustCompile(`^[0-9]{10}$`)

// LegacyAccountIdentityRepairReport 记录启动修复实际影响的历史账号数量。
type LegacyAccountIdentityRepairReport struct {
	VerifiedStudents       int64
	RestoredAuthorizations int64
}

// RepairLegacyAccountIdentityState 修复仅执行 AutoMigrate 后被默认值覆盖的历史身份状态。
// 修复依据只来自旧版本已经持久化的学号和教务绑定，不创建任何法律同意记录。
func RepairLegacyAccountIdentityState(db *gorm.DB) (LegacyAccountIdentityRepairReport, error) {
	var report LegacyAccountIdentityRepairReport
	if db == nil {
		return report, fmt.Errorf("database is nil")
	}

	err := db.Transaction(func(tx *gorm.DB) error {
		var candidates []User
		if err := tx.Select("id", "student_id", "qq", "edu_student_id", "edu_bound", "created_at").
			Where("student_verified_at IS NULL AND student_id <> ''").
			Find(&candidates).Error; err != nil {
			return fmt.Errorf("查询历史学生身份: %w", err)
		}

		now := time.Now()
		for _, user := range candidates {
			if !studentIdentityPattern.MatchString(user.StudentID) {
				continue
			}
			// 旧 QQ 注册会把 QQ 同时写入 student_id；除此之外，十位 student_id
			// 就是旧版已经建立的登录身份，即使当时没有同步教务绑定字段也应保留。
			if user.QQ == user.StudentID && user.EduStudentID != user.StudentID && !user.EduBound {
				continue
			}

			verifiedAt := user.CreatedAt
			if verifiedAt.IsZero() {
				verifiedAt = now
			}
			result := tx.Model(&User{}).
				Where("id = ? AND student_verified_at IS NULL", user.ID).
				UpdateColumn("student_verified_at", verifiedAt)
			if result.Error != nil {
				return fmt.Errorf("恢复历史学生身份 user_id=%d: %w", user.ID, result.Error)
			}
			report.VerifiedStudents += result.RowsAffected
		}

		result := tx.Model(&User{}).
			Where("edu_bound = ? AND edu_authorized = ? AND legal_consent_revoked_at IS NULL", true, false).
			Updates(map[string]interface{}{
				"edu_authorized":                 true,
				"edu_session_state":              "active",
				"edu_auto_relogin":               true,
				"edu_authorized_at":              now,
				"edu_session_updated_at":         now,
				"edu_authorization_generation":   gorm.Expr("CASE WHEN edu_authorization_generation < 1 THEN 1 ELSE edu_authorization_generation END"),
				"edu_binding_state":              "active",
				"edu_binding_pending_generation": 0,
				"edu_binding_pending_student_id": "",
				"edu_binding_started_at":         nil,
			})
		if result.Error != nil {
			return fmt.Errorf("恢复历史教务授权: %w", result.Error)
		}
		report.RestoredAuthorizations = result.RowsAffected
		return nil
	})
	if err != nil {
		return LegacyAccountIdentityRepairReport{}, err
	}
	return report, nil
}
