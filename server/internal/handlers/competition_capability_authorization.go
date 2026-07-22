package handlers

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type competitionCapabilityAIAccessInput struct {
	Enabled *bool `json:"enabled"`
}

type competitionCapabilityAIAccessResponse struct {
	Enabled   bool       `json:"enabled"`
	EnabledAt *time.Time `json:"enabled_at"`
}

// GetCompetitionCapabilityAIAccess 返回竞赛画像的独立 AI 授权状态。
func (h *CompetitionHandler) GetCompetitionCapabilityAIAccess(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	state, err := h.loadCompetitionCapabilityAIAccess(userID)
	if err != nil {
		writeCompetitionCapabilityAIAccessError(c, err)
		return
	}
	c.JSON(http.StatusOK, state)
}

// PutCompetitionCapabilityAIAccess 只更新竞赛画像授权，不影响其他 AI 或教务授权。
func (h *CompetitionHandler) PutCompetitionCapabilityAIAccess(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input competitionCapabilityAIAccessInput
	decoder := json.NewDecoder(c.Request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || input.Enabled == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "enabled 必须是布尔值"})
		return
	}
	if err := ensureJSONBodyEnded(decoder); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求只能包含一个 JSON 对象"})
		return
	}

	var state competitionCapabilityAIAccessResponse
	err := h.db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Select("id", "competition_profile_ai_enabled", "competition_profile_ai_enabled_at").First(&user, userID).Error; err != nil {
			return err
		}
		enabledAt := user.CompetitionProfileAIEnabledAt
		if *input.Enabled && !user.CompetitionProfileAIEnabled {
			now := time.Now()
			enabledAt = &now
		} else if !*input.Enabled {
			enabledAt = nil
		}
		if err := tx.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
			"competition_profile_ai_enabled":    *input.Enabled,
			"competition_profile_ai_enabled_at": enabledAt,
		}).Error; err != nil {
			return err
		}
		state = competitionCapabilityAIAccessResponse{Enabled: *input.Enabled, EnabledAt: enabledAt}
		return nil
	})
	if err != nil {
		writeCompetitionCapabilityAIAccessError(c, err)
		return
	}
	c.JSON(http.StatusOK, state)
}

// GetAICompetitionCapabilityProfile 在读取前实时检查专项授权；关闭后下一次请求立即拒绝。
func (h *CompetitionHandler) GetAICompetitionCapabilityProfile(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	state, err := h.loadCompetitionCapabilityAIAccess(userID)
	if err != nil {
		writeCompetitionCapabilityAIAccessError(c, err)
		return
	}
	if !state.Enabled {
		c.JSON(http.StatusForbidden, gin.H{
			"error": "未授权 AI 读取竞赛目标和能力画像",
			"code":  "competition_capability_profile_access_denied",
		})
		return
	}
	profile, err := h.loadCompetitionCapabilityProfile(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛能力画像失败"})
		return
	}
	c.JSON(http.StatusOK, profile)
}

func (h *CompetitionHandler) loadCompetitionCapabilityAIAccess(userID uint) (competitionCapabilityAIAccessResponse, error) {
	var user models.User
	err := h.db.Select("id", "competition_profile_ai_enabled", "competition_profile_ai_enabled_at").First(&user, userID).Error
	return competitionCapabilityAIAccessResponse{
		Enabled:   user.CompetitionProfileAIEnabled,
		EnabledAt: user.CompetitionProfileAIEnabledAt,
	}, err
}

func writeCompetitionCapabilityAIAccessError(c *gin.Context, err error) {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"error": "读取竞赛画像授权失败"})
}
