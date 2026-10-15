package handlers

import (
	"log"

	"shenliyuan/internal/models"
)

// 只清理真实可登录且唯一归属该用户的标识，不能解除共享出口或其他用户的防护。
func (h *AuthHandler) clearUserLoginFailures(user models.User) {
	candidates := []string{user.QQ}
	if user.EmailVerifiedAt != nil {
		candidates = append(candidates, user.Email)
	}
	switch {
	case h.db.Migrator().HasTable(&models.AccountLoginAlias{}):
		var aliases []models.AccountLoginAlias
		if err := h.db.Where("user_id = ?", user.ID).Find(&aliases).Error; err != nil {
			log.Printf("[LOGIN_THROTTLE_RECOVERY_FAILED] user_id=%d", user.ID)
			return
		}
		for _, alias := range aliases {
			candidates = append(candidates, alias.Value)
		}
	case h.db.Migrator().HasTable(&models.AcademicIdentityBinding{}):
		var bindings []models.AcademicIdentityBinding
		if err := h.db.Where("user_id = ?", user.ID).Find(&bindings).Error; err != nil {
			log.Printf("[LOGIN_THROTTLE_RECOVERY_FAILED] user_id=%d", user.ID)
			return
		}
		for _, binding := range bindings {
			candidates = append(candidates, binding.StudentID)
		}
	default:
		if user.StudentVerifiedAt != nil {
			candidates = append(candidates, user.StudentID)
		}
	}
	seen := make(map[string]bool)
	for _, candidate := range candidates {
		account := normalizeLoginAccount(candidate)
		if account == "" || seen[account] {
			continue
		}
		seen[account] = true
		owner, err := h.findLoginUser(account)
		if err == nil && owner.ID == user.ID {
			h.clearLoginFailures(loginThrottleScope("account", account))
		}
	}
}
