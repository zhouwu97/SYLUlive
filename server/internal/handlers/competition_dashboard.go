package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type competitionDashboardSummaryResponse struct {
	PreferenceConfigured   bool   `json:"preference_configured"`
	PrimaryGoal            string `json:"primary_goal"`
	PrimaryDirection       string `json:"primary_direction"`
	WeeklyHours            int    `json:"weekly_hours"`
	AwardTotal             int64  `json:"award_total"`
	VerifiedAwardCount     int64  `json:"verified_award_count"`
	SelfReportedAwardCount int64  `json:"self_reported_award_count"`
	PendingAwardCount      int64  `json:"pending_award_count"`
	RejectedAwardCount     int64  `json:"rejected_award_count"`
	CapabilityReady        bool   `json:"capability_ready"`
}

type competitionAwardStatusCount struct {
	VerificationStatus string
	Count              int64
}

// GetCompetitionDashboard 返回主页与“我的竞赛”页所需的轻量摘要。
// 该接口只读取当前用户的偏好和经历状态计数，不加载经历详情或证明材料。
func (h *CompetitionHandler) GetCompetitionDashboard(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}

	summary, err := h.loadCompetitionDashboard(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛档案摘要失败"})
		return
	}
	c.JSON(http.StatusOK, summary)
}

func (h *CompetitionHandler) loadCompetitionDashboard(userID uint) (competitionDashboardSummaryResponse, error) {
	summary := competitionDashboardSummaryResponse{}

	var preference models.UserCompetitionPreference
	if err := h.db.Where("user_id = ?", userID).First(&preference).Error; err == nil {
		summary.PreferenceConfigured = true
		summary.WeeklyHours = preference.WeeklyHours
		goals := decodeStringArray(preference.Goals)
		if len(goals) > 0 {
			summary.PrimaryGoal = goals[0]
		}
		directions := decodeStringArray(preference.DirectionTags)
		if len(directions) > 0 {
			summary.PrimaryDirection = directions[0]
		}
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return summary, err
	}

	var counts []competitionAwardStatusCount
	if err := h.db.Model(&models.UserCompetitionAward{}).
		Select("verification_status, COUNT(*) AS count").
		Where("user_id = ?", userID).
		Group("verification_status").
		Scan(&counts).Error; err != nil {
		return summary, err
	}
	for _, item := range counts {
		summary.AwardTotal += item.Count
		switch item.VerificationStatus {
		case "verified":
			summary.VerifiedAwardCount = item.Count
		case "self_reported":
			summary.SelfReportedAwardCount = item.Count
		case "pending":
			summary.PendingAwardCount = item.Count
		case "rejected":
			summary.RejectedAwardCount = item.Count
		}
	}
	summary.CapabilityReady = summary.PreferenceConfigured ||
		summary.VerifiedAwardCount+summary.SelfReportedAwardCount > 0
	return summary, nil
}
