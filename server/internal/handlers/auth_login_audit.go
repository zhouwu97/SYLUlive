package handlers

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// 成功流水逐条保留；安全中心的五分钟聚合记录用于检索，不能代替登录流水。
func (h *AuthHandler) recordSuccessfulLogin(c *gin.Context, user models.User, account, family string) {
	if h.security == nil {
		return
	}
	ctx, cancel := context.WithTimeout(securityAuditContext(c), 500*time.Millisecond)
	defer cancel()
	db := h.db.WithContext(ctx)
	ua := strings.TrimSpace(c.GetHeader("User-Agent"))
	installation := strings.TrimSpace(c.GetHeader("X-Installation-ID"))
	var previous, known int64
	history := db.Model(&models.RefreshToken{}).Where("user_id = ? AND token_family <> ?", user.ID, family)
	newDevice := false
	// UA / 安装标识是可伪造的观察信号，不用于授权；缺失指纹时不猜测新设备。
	if ua != "" || installation != "" {
		if err := history.Count(&previous).Error; err == nil && previous > 0 {
			query := db.Model(&models.RefreshToken{}).Where("user_id = ? AND token_family <> ?", user.ID, family)
			if installation != "" {
				query = query.Where("installation_id_hash = ?", refreshHash(installation))
			} else {
				query = query.Where("user_agent_hash = ?", refreshHash(ua))
			}
			if err := query.Count(&known).Error; err == nil {
				newDevice = known == 0
			}
		}
	}
	requestID := middleware.EnsureRequestID(c)
	metadata, _ := json.Marshal(map[string]interface{}{
		"request_id": requestID, "source_hash": h.security.SourceFingerprint(c.ClientIP()),
		"user_agent_hash": h.security.Hash(ua), "installation_hash": h.security.Hash(installation),
		"session_family_hash": h.security.Hash(family), "new_device": newDevice,
	})
	if err := db.Create(&models.AccountSecurityAuditLog{UserID: user.ID, Action: "login_success", Metadata: string(metadata)}).Error; err != nil {
		log.Printf("[LOGIN_SUCCESS_AUDIT_FAILED] user_id=%d request_id=%s", user.ID, requestID)
	}
	input := services.SecurityEventInput{
		EventType: "login_success", Severity: models.SecuritySeverityInfo,
		Route: "/api/login", Method: http.MethodPost, ClientIP: c.ClientIP(),
		UserAgent: ua, InstallationID: installation, ActorUserID: &user.ID,
		TargetType: "account", TargetValue: account, TargetMasked: maskLoginSecurityTarget(account),
		RequestID: requestID, Action: "observed",
	}
	_ = h.security.RecordContext(securityAuditContext(c), input)
	if newDevice {
		input.EventType = "login_new_device"
		if user.Role == models.RoleAdmin || user.Role == models.RoleSuperAdmin {
			input.EventType = "admin_login_new_device"
			input.Severity = models.SecuritySeverityHigh
		}
		_ = h.security.RecordContext(securityAuditContext(c), input)
	}
}
