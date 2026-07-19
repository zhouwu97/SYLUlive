package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
)

const (
	aiHourlyLimit     = 3
	aiWindowSeconds   = 60 * 60
	aiMaxMessageChars = 20
)

// AICapabilitiesHandler 返回当前账号可见的 AI 能力。
// P0 仅开放入口与状态验证，不暴露 Provider 配置，也不提供真实对话能力。
type AICapabilitiesHandler struct {
	enabled          bool
	internalTestOnly bool
	allowedUserIDs   map[string]struct{}
}

func NewAICapabilitiesHandler(enabled, internalTestOnly bool, allowedUserIDs []string) *AICapabilitiesHandler {
	allowed := make(map[string]struct{}, len(allowedUserIDs))
	for _, id := range allowedUserIDs {
		if normalized := strings.TrimSpace(id); normalized != "" {
			allowed[normalized] = struct{}{}
		}
	}
	return &AICapabilitiesHandler{
		enabled:          enabled,
		internalTestOnly: internalTestOnly,
		allowedUserIDs:   allowed,
	}
}

// Get 处理 GET /api/ai/capabilities。
// 未获内测资格时仍返回 200，由客户端安静隐藏入口，避免影响“校园”页其他模块。
func (h *AICapabilitiesHandler) Get(c *gin.Context) {
	userID := strconv.FormatUint(uint64(c.GetUint("user_id")), 10)
	accessAllowed := h.enabled
	if accessAllowed && h.internalTestOnly {
		role := c.GetString("role")
		_, whitelisted := h.allowedUserIDs[userID]
		accessAllowed = whitelisted || role == "admin" || role == "super_admin"
	}

	c.JSON(http.StatusOK, gin.H{
		"enabled":            h.enabled,
		"access_allowed":     accessAllowed,
		"internal_test_only": h.internalTestOnly,
		"phase":              "p0",
		"chat_enabled":       false,
		"features": gin.H{
			"policy_rag":       false,
			"schedule_windows": false,
		},
		"quota": gin.H{
			"limit":          aiHourlyLimit,
			"remaining":      aiHourlyLimit,
			"window_seconds": aiWindowSeconds,
			"reset_at":       nil,
		},
		"max_message_chars": aiMaxMessageChars,
	})
}
