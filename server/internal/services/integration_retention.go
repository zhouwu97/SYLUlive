package services

import (
	"context"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"time"
)

// 调用者已持有用户行锁。注销、撤销协议和教务换绑与发布按同一锁顺序生效。
func InvalidateUserIntegrations(tx *gorm.DB, owner uint, now time.Time) error {
	if !tx.Migrator().HasTable(&models.IntegrationBinding{}) {
		return nil
	}
	if err := tx.Model(&models.IntegrationBinding{}).Where("owner_id = ? AND state = ?", owner, "active").Updates(map[string]interface{}{"state": "revoked", "epoch": gorm.Expr("epoch + 1"), "revoked_at": now}).Error; err != nil {
		return err
	}
	return tx.Model(&models.IntegrationAction{}).Where("owner_id = ? AND state = ?", owner, "pending").Updates(map[string]interface{}{"state": "invalidated", "payload": "{}", "confirm_nonce_hash": "", "confirm_expires_at": nil}).Error
}

// 小规模定时清理复用 PostgreSQL；不为凭据与草稿维护另一个队列。
func (s *IntegrationAuthService) Purge(ctx context.Context) error {
	now := s.Now()
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.IntegrationAction{}).Where("state = ? AND expires_at <= ?", "pending", now).Updates(map[string]interface{}{"state": "expired", "payload": "{}", "confirm_nonce_hash": "", "confirm_expires_at": nil}).Error; err != nil {
			return err
		}
		queries := []func() *gorm.DB{
			func() *gorm.DB {
				return tx.Where("expires_at < ?", now.Add(-24*time.Hour)).Delete(&models.IntegrationDeviceRequest{})
			},
			func() *gorm.DB { return tx.Where("expires_at < ?", now).Delete(&models.IntegrationRateBucket{}) },
			func() *gorm.DB {
				return tx.Where("(kind = ? AND expires_at < ?) OR absolute_expires_at < ?", "access", now, now).Delete(&models.IntegrationCredential{})
			},
			func() *gorm.DB {
				return tx.Where("expires_at < ?", now.Add(-30*24*time.Hour)).Delete(&models.IntegrationAction{})
			},
			func() *gorm.DB {
				return tx.Where("created_at < ?", now.Add(-180*24*time.Hour)).Delete(&models.IntegrationAudit{})
			},
			func() *gorm.DB {
				return tx.Where("state = ? AND revoked_at < ?", "revoked", now.Add(-180*24*time.Hour)).Delete(&models.IntegrationBinding{})
			},
		}
		for _, q := range queries {
			if err := q().Error; err != nil {
				return err
			}
		}
		return nil
	})
}
