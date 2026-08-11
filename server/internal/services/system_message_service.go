package services

import (
	"errors"
	"fmt"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

const (
	SystemUserStudentID = "system_auto"
	SystemUserNickname  = "系统自动发出"
)

// EnsureSystemUser 创建或修复不可登录的系统管理员账号。
func EnsureSystemUser(tx *gorm.DB) (models.User, error) {
	var user models.User
	err := tx.Where("student_id = ?", SystemUserStudentID).First(&user).Error
	if err == nil {
		updates := map[string]any{}
		roleChanged := user.Role != models.RoleAdmin
		if user.Nickname != SystemUserNickname {
			updates["nickname"] = SystemUserNickname
		}
		if user.PasswordHash == "" {
			updates["password_hash"] = "system_auto_no_login"
		}
		if user.CreditScore == 0 {
			updates["credit_score"] = 100
		}
		if roleChanged {
			if err := UpdateUserRoleAndInvalidateToken(tx, user.ID, models.RoleAdmin); err != nil {
				return models.User{}, err
			}
		}
		if len(updates) > 0 {
			if err := tx.Model(&user).Updates(updates).Error; err != nil {
				return models.User{}, err
			}
		}
		if roleChanged || len(updates) > 0 {
			if err := tx.First(&user, user.ID).Error; err != nil {
				return models.User{}, err
			}
		}
		return user, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return models.User{}, err
	}

	user = models.User{
		Nickname:     SystemUserNickname,
		StudentID:    SystemUserStudentID,
		PasswordHash: "system_auto_no_login",
		Role:         models.RoleAdmin,
		CreditScore:  100,
	}
	if err := tx.Create(&user).Error; err == nil {
		return user, nil
	}
	if err := tx.Where("student_id = ?", SystemUserStudentID).First(&user).Error; err != nil {
		return models.User{}, err
	}
	return user, nil
}

// GetOrCreateConversation 统一会话用户顺序，并在并发创建冲突后回读既有会话。
func GetOrCreateConversation(tx *gorm.DB, user1ID, user2ID uint, now time.Time) (models.Conversation, error) {
	if user1ID == 0 || user2ID == 0 || user1ID == user2ID {
		return models.Conversation{}, fmt.Errorf("会话用户无效")
	}
	if user1ID > user2ID {
		user1ID, user2ID = user2ID, user1ID
	}

	var conversation models.Conversation
	err := tx.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).First(&conversation).Error
	if err == nil {
		return conversation, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return models.Conversation{}, err
	}

	conversation = models.Conversation{User1ID: user1ID, User2ID: user2ID, LastMessageAt: now}
	createErr := tx.Create(&conversation).Error
	if createErr == nil {
		return conversation, nil
	}
	if err := tx.Where("user1_id = ? AND user2_id = ?", user1ID, user2ID).First(&conversation).Error; err == nil {
		return conversation, nil
	}
	return models.Conversation{}, createErr
}

// CreateSystemMessage 在现有事务内写入系统私信，不经过陌生人私信限制。
func CreateSystemMessage(tx *gorm.DB, targetUserID uint, content string) (models.Message, models.User, error) {
	if targetUserID == 0 {
		return models.Message{}, models.User{}, fmt.Errorf("目标用户无效")
	}
	var target models.User
	if err := tx.Select("id").First(&target, targetUserID).Error; err != nil {
		return models.Message{}, models.User{}, err
	}

	systemUser, err := EnsureSystemUser(tx)
	if err != nil {
		return models.Message{}, models.User{}, err
	}
	if systemUser.ID == targetUserID {
		return models.Message{}, models.User{}, fmt.Errorf("系统账号不能给自己发送私信")
	}

	now := time.Now()
	conversation, err := GetOrCreateConversation(tx, systemUser.ID, targetUserID, now)
	if err != nil {
		return models.Message{}, models.User{}, err
	}
	message := models.Message{
		ConversationID: conversation.ID,
		SenderID:       systemUser.ID,
		Content:        content,
	}
	if err := tx.Create(&message).Error; err != nil {
		return models.Message{}, models.User{}, err
	}
	if err := tx.Model(&conversation).Update("last_message_at", message.CreatedAt).Error; err != nil {
		return models.Message{}, models.User{}, err
	}
	message.Sender = systemUser
	return message, systemUser, nil
}
