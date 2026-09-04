package services

import (
	"fmt"
	"log"

	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/utils"
)

type NotificationService struct {
	db                *gorm.DB
	jpushAppKey       string
	jpushMasterSecret string
}

func NewNotificationService(db *gorm.DB, jpushAppKey, jpushMasterSecret string) *NotificationService {
	return &NotificationService{
		db:                db,
		jpushAppKey:       jpushAppKey,
		jpushMasterSecret: jpushMasterSecret,
	}
}

func (s *NotificationService) Notify(userID uint, title, content string, extras map[string]interface{}) error {
	if s == nil || s.db == nil || s.jpushAppKey == "" || s.jpushMasterSecret == "" {
		err := fmt.Errorf("JPush is not configured")
		log.Printf("[JPUSH_ERROR] %v", err)
		return err
	}
	var devices []models.PushDevice
	if err := s.db.Where("user_id = ? AND enabled = ? AND registration_id <> ''", userID, true).
		Find(&devices).Error; err != nil {
		return fmt.Errorf("读取推送设备失败: %w", err)
	}

	client := utils.NewJPushClient(s.jpushAppKey, s.jpushMasterSecret)
	if len(devices) == 0 {
		// 兼容旧客户端的设备注册号；它仍是 RegistrationID，不是可由用户控制的 Alias。
		var user struct{ DeviceToken string }
		if err := s.db.Model(&models.User{}).Select("device_token").First(&user, userID).Error; err != nil {
			return fmt.Errorf("读取用户推送设备失败: %w", err)
		}
		if user.DeviceToken == "" {
			return nil
		}
		return client.SendNotification(user.DeviceToken, title, content, extras)
	}

	var lastErr error
	for _, device := range devices {
		if err := client.SendRegistrationNotification(device.RegistrationID, device.Platform, title, content, extras); err != nil {
			lastErr = err
			log.Printf("[JPUSH_ERROR] registration push failed user_id=%d platform=%s: %v", userID, device.Platform, err)
		}
	}
	return lastErr
}
