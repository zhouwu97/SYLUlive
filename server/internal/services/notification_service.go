package services

import (
	"fmt"
	"log"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
	textutils "shenliyuan/internal/utils"
	"shenliyuan/utils"
)

// CreateReplyNotification 可参与发布事务；返回 nil 表示自回复或该事件已通知。
// 站内通知按事件去重，外部推送由调用者在提交后触发。
func CreateReplyNotification(db *gorm.DB, toUserID, fromUserID, replyID, postID uint, content string) (*models.Notification, error) {
	if toUserID == 0 || toUserID == fromUserID {
		return nil, nil
	}
	n := models.Notification{
		UserID: toUserID, Type: "reply", Content: textutils.TruncateGraphemes(content, 80),
		RelatedID: replyID, PostID: postID, FromUID: fromUserID,
		DedupKey: fmt.Sprintf("reply:%d", replyID), IsRead: false,
	}
	result := db.Clauses(clause.OnConflict{
		Columns:     []clause.Column{{Name: "user_id"}, {Name: "type"}, {Name: "dedup_key"}},
		TargetWhere: clause.Where{Exprs: []clause.Expression{clause.Expr{SQL: "dedup_key <> ''"}}},
		DoNothing:   true,
	}).Create(&n)
	if result.Error != nil {
		return nil, result.Error
	}
	if result.RowsAffected == 0 {
		return nil, nil
	}
	return &n, nil
}

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
