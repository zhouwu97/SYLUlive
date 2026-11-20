package services

import (
	"crypto/subtle"
	"strings"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"
)

func securityHasAccountTarget(eventType, targetType string) bool {
	return models.SecurityEventRetainsEvidence(eventType) && (targetType == "account" || targetType == "email")
}

func (s *SecurityEventService) targetAccountEncryptionKey() string {
	return s.Hash("security-event/target-account/aes-gcm/v1")
}

func (s *SecurityEventService) encryptTargetAccount(input SecurityEventInput) (string, error) {
	raw := strings.TrimSpace(input.TargetValue)
	if len(s.secret) == 0 || !securityHasAccountTarget(input.EventType, input.TargetType) || raw == "" || !utf8.ValidString(raw) || utf8.RuneCountInString(raw) > 320 {
		return "", nil
	}
	// 使用独立用途密钥，完整目标不进入通用 JSON、日志或外发邮件。
	return utils.EncryptAES(raw, s.targetAccountEncryptionKey())
}

// TargetAccount 仅供管理员 DTO 使用。目标无需是已注册账号，避免丢失输错的登录名或扫描目标。
func (s *SecurityEventService) TargetAccount(event models.SecurityEvent) (string, string) {
	if !securityHasAccountTarget(event.EventType, event.TargetType) {
		return "", ""
	}
	if event.TargetAccountCiphertext == "" {
		return "", "not_recorded"
	}
	if s == nil || len(s.secret) == 0 {
		return "", "unavailable"
	}
	raw, err := utils.DecryptAES(event.TargetAccountCiphertext, s.targetAccountEncryptionKey())
	if err != nil || raw == "" || !utf8.ValidString(raw) || utf8.RuneCountInString(raw) > 320 || subtle.ConstantTimeCompare([]byte(s.Hash(raw)), []byte(event.TargetHash)) != 1 {
		return "", "unavailable"
	}
	return raw, "available"
}
