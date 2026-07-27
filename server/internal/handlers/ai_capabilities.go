package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/ai"
)

const (
	aiHourlyLimit     = 3
	aiWindowSeconds   = 60 * 60
	aiMaxMessageChars = 120
)

// AICapabilitiesHandler 返回当前账号可见的 AI 能力。
// P0 仅开放入口与状态验证，不暴露 Provider 配置，也不提供真实对话能力。
type AICapabilitiesHandler struct {
	enabled          bool
	internalTestOnly bool
	allowedUserIDs   map[string]struct{}
	runtime          *ai.Runtime
	policyRAGEnabled bool
	hourlyLimit      int
	maxMessageChars  int
}

type AICapabilitiesOptions struct {
	Runtime          *ai.Runtime
	PolicyRAGEnabled bool
	HourlyLimit      int
	MaxMessageChars  int
}

func NewAICapabilitiesHandler(enabled, internalTestOnly bool, allowedUserIDs []string, options ...AICapabilitiesOptions) *AICapabilitiesHandler {
	allowed := make(map[string]struct{}, len(allowedUserIDs))
	for _, id := range allowedUserIDs {
		if normalized := strings.TrimSpace(id); normalized != "" {
			allowed[normalized] = struct{}{}
		}
	}
	handler := &AICapabilitiesHandler{
		enabled:          enabled,
		internalTestOnly: internalTestOnly,
		allowedUserIDs:   allowed,
		hourlyLimit:      aiHourlyLimit,
		maxMessageChars:  aiMaxMessageChars,
	}
	if len(options) > 0 {
		handler.runtime = options[0].Runtime
		handler.policyRAGEnabled = options[0].PolicyRAGEnabled
		if options[0].HourlyLimit > 0 {
			handler.hourlyLimit = options[0].HourlyLimit
		}
		if options[0].MaxMessageChars > 0 {
			handler.maxMessageChars = options[0].MaxMessageChars
		}
	}
	return handler
}

// Get 处理 GET /api/ai/capabilities。
// 未获内测资格时仍返回 200，由客户端安静隐藏入口，避免影响“校园”页其他模块。
func (h *AICapabilitiesHandler) Get(c *gin.Context) {
	numericUserID := c.GetUint("user_id")
	userID := strconv.FormatUint(uint64(numericUserID), 10)
	accessAllowed := h.enabled
	if accessAllowed && h.internalTestOnly {
		role := c.GetString("role")
		_, whitelisted := h.allowedUserIDs[userID]
		accessAllowed = whitelisted || role == "admin" || role == "super_admin"
	}
	remaining := h.hourlyLimit
	var resetAt interface{}
	if h.runtime != nil && accessAllowed {
		if value, reset, err := h.runtime.Quota(c.Request.Context(), numericUserID); err == nil {
			remaining = value
			resetAt = reset
		}
	}
	chatEnabled := accessAllowed && h.runtime != nil && h.policyRAGEnabled
	phase := "p0"
	if h.runtime != nil {
		phase = "p1"
	}
	if h.policyRAGEnabled {
		phase = "p2"
	}

	c.JSON(http.StatusOK, gin.H{
		"enabled":            h.enabled,
		"access_allowed":     accessAllowed,
		"internal_test_only": h.internalTestOnly,
		"phase":              phase,
		"chat_enabled":       chatEnabled,
		"features": gin.H{
			"policy_rag":       accessAllowed && h.policyRAGEnabled,
			"schedule_windows": false,
		},
		"quota": gin.H{
			"limit":          h.hourlyLimit,
			"remaining":      remaining,
			"window_seconds": aiWindowSeconds,
			"reset_at":       resetAt,
		},
		"max_message_chars": h.maxMessageChars,
	})
}
