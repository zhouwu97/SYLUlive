package handlers

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/ai"
)

// AIScheduleHandler 暴露确定性课表 Skill。它不接受 user_id，身份始终来自 JWT Context。
type AIScheduleHandler struct {
	skill   *ai.ScheduleSkill
	enabled bool
}

func NewAIScheduleHandler(skill *ai.ScheduleSkill, enabled bool) *AIScheduleHandler {
	return &AIScheduleHandler{skill: skill, enabled: enabled}
}

func (h *AIScheduleHandler) Windows(c *gin.Context) {
	if !h.enabled || h.skill == nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"code":    "schedule_skill_disabled",
			"message": "课表 Skill 尚未完成校历和节次配置核验",
		})
		return
	}
	var request ai.ScheduleWindowsArguments
	if err := decodeStrictJSON(c, &request, 16<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_schedule_request", "message": "课表查询参数格式错误"})
		return
	}
	result, err := h.skill.Execute(c.Request.Context(), c.GetUint("user_id"), request)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "invalid_schedule_request", "message": err.Error()})
		return
	}
	if result.Status == "data_unavailable" {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"result": result})
		return
	}
	c.JSON(http.StatusOK, gin.H{"result": result})
}
