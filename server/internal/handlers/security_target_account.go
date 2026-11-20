package handlers

import (
	"context"
	"strings"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// 历史登录预警只保存目标摘要。从现有账号核对邮箱，不新增明文审计存储；
// 遮罩仅用于缩小查询范围，必须同时匹配 HMAC，不能按邮箱前缀猜测账号。
func (h *SecurityAdminHandler) securityTargetAccounts(ctx context.Context, events []models.SecurityEvent) (map[uint]string, error) {
	result := make(map[uint]string)
	if h.security == nil {
		return result, nil
	}
	ctx, cancel := context.WithTimeout(ctx, services.SecurityOverviewBudget)
	defer cancel()
	// 同一页的多个时间桶可能对应同一遮罩，只查询一次。
	candidatesByMask := make(map[string][]string)
	for _, event := range events {
		if event.EventType != "login_bruteforce" || event.TargetType != "account" || event.TargetHash == "" || event.TargetAccountCiphertext != "" {
			continue
		}
		prefix, domain, ok := strings.Cut(event.TargetMasked, "***@")
		if !ok || domain == "" || strings.Contains(domain, "@") || len([]rune(prefix)) < 1 || len([]rune(prefix)) > 2 {
			continue
		}
		candidates, queried := candidatesByMask[event.TargetMasked]
		if !queried {
			// 转义 LIKE 通配符；邮箱允许的 %、_ 不能扩大候选范围。
			escape := strings.NewReplacer("!", "!!", "%", "!%", "_", "!_")
			pattern := escape.Replace(prefix) + "%@" + escape.Replace(domain)
			if err := h.db.WithContext(ctx).Model(&models.User{}).
				Where("account_status = ? AND email LIKE ? ESCAPE '!'", "active", pattern).
				Pluck("email", &candidates).Error; err != nil {
				return nil, err
			}
			candidatesByMask[event.TargetMasked] = candidates
		}
		for _, email := range candidates {
			if maskLoginSecurityTarget(email) == event.TargetMasked && h.security.Hash(email) == event.TargetHash {
				result[event.ID] = email
				break
			}
		}
	}
	return result, nil
}
