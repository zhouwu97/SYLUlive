package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/ai"
)

const (
	aiHourlyLimit     = 3
	aiWindowSeconds   = 60 * 60
	aiMaxMessageChars = 20
)

// AICapabilitiesHandler 返回当前账号可见的 AI 能力。
// P0 仅开放入口与状态验证，不暴露 Provider 配置，也不提供真实对话能力。
type AICapabilitiesHandler struct {
	enabled               bool
	runtime               *ai.Runtime
	policyRAGEnabled      bool
	hourlyLimit           int
	maxMessageChars       int
	quotaExemptUserIDs    map[uint]struct{}
	externalMCPConfigured bool
	externalMCPHealth     externalMCPHealthReader
	toolRegistry          *ai.ToolRegistry
}

type externalMCPHealthReader interface {
	Healthy() bool
}

type AICapabilitiesOptions struct {
	Runtime               *ai.Runtime
	PolicyRAGEnabled      bool
	HourlyLimit           int
	MaxMessageChars       int
	QuotaExemptUserIDs    []uint
	ExternalMCPConfigured bool
	ExternalMCPHealth     externalMCPHealthReader
	ToolRegistry          *ai.ToolRegistry
}

func NewAICapabilitiesHandler(enabled bool, options ...AICapabilitiesOptions) *AICapabilitiesHandler {
	handler := &AICapabilitiesHandler{
		enabled:         enabled,
		hourlyLimit:     aiHourlyLimit,
		maxMessageChars: aiMaxMessageChars,
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
		handler.quotaExemptUserIDs = make(map[uint]struct{}, len(options[0].QuotaExemptUserIDs))
		for _, userID := range options[0].QuotaExemptUserIDs {
			if userID != 0 {
				handler.quotaExemptUserIDs[userID] = struct{}{}
			}
		}
		handler.externalMCPConfigured = options[0].ExternalMCPConfigured
		handler.externalMCPHealth = options[0].ExternalMCPHealth
		handler.toolRegistry = options[0].ToolRegistry
	}
	return handler
}

// Get 处理 GET /api/ai/capabilities。
// 所有通过认证的账号共享相同访问能力，配额与预算仍按账号独立计算。
func (h *AICapabilitiesHandler) Get(c *gin.Context) {
	numericUserID := c.GetUint("user_id")
	accessAllowed := h.enabled
	remaining := h.hourlyLimit
	unlimited := false
	var resetAt interface{}
	if h.runtime != nil && accessAllowed {
		if quota, err := h.runtime.Quota(c.Request.Context(), numericUserID); err == nil {
			remaining = quota.Remaining
			resetAt = quota.ResetAt
			unlimited = quota.Unlimited
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
	externalMCPAvailable := accessAllowed && h.externalMCPConfigured &&
		h.externalMCPHealth != nil && h.externalMCPHealth.Healthy()

	c.JSON(http.StatusOK, gin.H{
		"enabled":            h.enabled,
		"access_allowed":     accessAllowed,
		"internal_test_only": false, // 保留旧客户端协议字段，访问限制已永久停用。
		"phase":              phase,
		"chat_enabled":       chatEnabled,
		"features": gin.H{
			"policy_rag":              accessAllowed && h.policyRAGEnabled,
			"schedule_windows":        false,
			"hy3_competition_compare": externalMCPAvailable && h.toolRegistry.HasTool("hy3_decision.compare_competitions"),
			"hy3_academic_analysis":   externalMCPAvailable && h.toolRegistry.HasTool("hy3_decision.analyze_academic"),
			"hy3_week_plan":           externalMCPAvailable && h.toolRegistry.HasTool("hy3_decision.plan_student_week"),
		},
		"quota": gin.H{
			"limit":          h.hourlyLimit,
			"remaining":      remaining,
			"window_seconds": aiWindowSeconds,
			"reset_at":       resetAt,
			"unlimited":      unlimited,
		},
		"max_message_chars": h.maxMessageChars,
	})
}
