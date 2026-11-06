package services

import (
	"context"
	"errors"
	"strings"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

// CancelDevice 由持有本次设备秘密的客户端取消请求，不接受网页代码或目标账号。
// 即使网页已批准而客户端尚未领到token，也能撤销该请求产生的绑定。
func (s *IntegrationAuthService) CancelDevice(ctx context.Context, raw string) error {
	if !strings.HasPrefix(raw, "sd_") || len(raw) > 128 {
		return integrationError("invalid_request", 400)
	}
	var snapshot models.IntegrationDeviceRequest
	err := s.DB.WithContext(ctx).Where("device_hash = ?", IntegrationSecretHash(raw)).Take(&snapshot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return integrationError("device_request_unavailable", 410)
	}
	if err != nil {
		return err
	}
	mutate := func(tx *gorm.DB) error {
		var row models.IntegrationDeviceRequest
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&row, "id = ?", snapshot.ID).Error; err != nil {
			return err
		}
		if row.OwnerID != snapshot.OwnerID {
			// 首次网页查看可能刚刚认领owner；不能在设备锁后反向获取用户锁。
			return integrationError("authorization_changed", 409)
		}
		if row.State == "denied" {
			return nil
		}
		if row.BindingID != "" {
			var binding models.IntegrationBinding
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
				"id = ? AND owner_id = ? AND installation_id = ?", row.BindingID, row.OwnerID, row.InstallationID,
			).Take(&binding).Error; err != nil {
				return err
			}
			if binding.State == "active" {
				if err := s.revokeTx(tx, binding); err != nil {
					return err
				}
			}
		}
		return tx.Model(&row).Updates(map[string]interface{}{"state": "denied", "nonce_hash": ""}).Error
	}
	if snapshot.OwnerID != 0 {
		return s.ownerTx(ctx, snapshot.OwnerID, func(tx *gorm.DB, _ models.User) error { return mutate(tx) })
	}
	release := AcquireContentWriteSerialLock(s.DB)
	defer release()
	return s.DB.WithContext(ctx).Transaction(mutate)
}
