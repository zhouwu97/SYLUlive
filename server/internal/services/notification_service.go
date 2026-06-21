package services

import (
	"log"
	"strconv"

	"shenliyuan/utils"
)

type NotificationService struct {
	jpushAppKey       string
	jpushMasterSecret string
}

func NewNotificationService(jpushAppKey, jpushMasterSecret string) *NotificationService {
	return &NotificationService{
		jpushAppKey:       jpushAppKey,
		jpushMasterSecret: jpushMasterSecret,
	}
}

func (s *NotificationService) Notify(userID uint, title, content string, extras map[string]interface{}) error {
	if s == nil || s.jpushAppKey == "" || s.jpushMasterSecret == "" {
		log.Printf("[JPUSH_WARN] JPush is not configured; skip notification user=%d type=%v", userID, extras["type"])
		return nil
	}
	alias := strconv.FormatUint(uint64(userID), 10)
	overrideMsgID, _ := extras["override_msg_id"].(string)
	return utils.NewJPushClient(s.jpushAppKey, s.jpushMasterSecret).
		SendAliasNotification(alias, title, content, extras, overrideMsgID)
}
