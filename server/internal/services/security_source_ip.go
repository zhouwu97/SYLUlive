package services

import (
	"crypto/subtle"
	"net/netip"
	"strings"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"
)

// 单独派生加密用途的密钥，不直接把 HMAC 密钥当作 AES 密钥。
func (s *SecurityEventService) sourceIPEncryptionKey() string {
	return s.Hash("security-event/source-ip/aes-gcm/v1")
}

func (s *SecurityEventService) encryptSourceIP(input SecurityEventInput, sourceHash string, valid bool) (string, error) {
	if !valid || len(s.secret) == 0 || !models.SecurityEventActionable(input.EventType) {
		return "", nil
	}
	raw := strings.TrimSpace(input.ClientIP)
	address, err := netip.ParseAddr(raw)
	if err != nil || address.Zone() != "" || sourceHash != s.Hash(raw) {
		return "", nil
	}
	// 密文绑定来源指纹；不允许把客户端提供的哈希当作归因依据。
	return utils.EncryptAES(raw, s.sourceIPEncryptionKey())
}

// SourceIP 仅供管理员 DTO 调用；json 序列化模型永远不会泄露 IP 或密文。
func (s *SecurityEventService) SourceIP(event models.SecurityEvent) (string, string) {
	if !event.SourceAttributionValid {
		return "", "untrusted"
	}
	if !models.SecurityEventActionable(event.EventType) || event.SourceIPCiphertext == "" {
		return "", "not_recorded"
	}
	if s == nil || len(s.secret) == 0 {
		return "", "unavailable"
	}
	raw, err := utils.DecryptAES(event.SourceIPCiphertext, s.sourceIPEncryptionKey())
	if err != nil || subtle.ConstantTimeCompare([]byte(s.Hash(raw)), []byte(event.SourceIPHash)) != 1 {
		return "", "unavailable"
	}
	address, err := netip.ParseAddr(raw)
	if err != nil || address.Zone() != "" {
		return "", "unavailable"
	}
	return address.Unmap().String(), "available"
}
