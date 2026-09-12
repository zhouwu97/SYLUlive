package services

import (
	"time"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

// UpdateUserRoleAndInvalidateToken 更新用户角色并让旧登录态立即失效。
func UpdateUserRoleAndInvalidateToken(db *gorm.DB, userID uint, role models.Role) error {
	if err := db.Model(&models.User{}).
		Where("id = ?", userID).
		Updates(map[string]interface{}{
			"role":          role,
			"token_version": gorm.Expr("token_version + 1"),
		}).Error; err != nil {
		return err
	}

	middleware.InvalidateTokenVersionCache(userID)
	if db.Migrator().HasTable(&models.RefreshToken{}) {
		_ = db.Model(&models.RefreshToken{}).
			Where("user_id = ? AND revoked_at IS NULL", userID).
			Update("revoked_at", time.Now()).Error
	}
	return nil
}
