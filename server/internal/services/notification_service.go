package services

import (
	"fmt"
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
		err := fmt.Errorf("JPush is not configured: appKey=%q masterSecret=%q", s.jpushAppKey, s.jpushMasterSecret)
		log.Printf("[JPUSH_ERROR] %v", err)
		return err
	}
	alias := strconv.FormatUint(uint64(userID), 10)
	return utils.NewJPushClient(s.jpushAppKey, s.jpushMasterSecret).
		SendAliasNotification(alias, title, content, extras)
}
