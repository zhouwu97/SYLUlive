package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// CheckInCompensationHandler 提供补偿活动的用户领取和超级管理员发布接口。
type CheckInCompensationHandler struct {
	db      *gorm.DB
	service *services.CheckInCompensationService
}

func NewCheckInCompensationHandler(db *gorm.DB) *CheckInCompensationHandler {
	return &CheckInCompensationHandler{db: db, service: services.NewCheckInCompensationService(db)}
}

type publishCheckInCompensationInput struct {
	Title          string                                  `json:"title" binding:"required"`
	Description    string                                  `json:"description"`
	ClaimStartDate string                                  `json:"claim_start_date" binding:"required"`
	ClaimEndDate   string                                  `json:"claim_end_date" binding:"required"`
	Targets        []publishCheckInCompensationTargetInput `json:"targets" binding:"required,min=1"`
}

type publishCheckInCompensationTargetInput struct {
	UserID      uint   `json:"user_id" binding:"required"`
	CheckInDate string `json:"check_in_date" binding:"required"`
	ExpReward   int    `json:"exp_reward" binding:"required,min=1,max=10000"`
	Reason      string `json:"reason"`
}

// Publish 发布活动时同时写入用户资格快照，后续不会因用户资料变化而改变资格。
func (h *CheckInCompensationHandler) Publish(c *gin.Context) {
	operatorID := c.GetUint("user_id")
	var input publishCheckInCompensationInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "补偿活动参数无效"})
		return
	}
	start, err := parseAPICheckInDate(input.ClaimStartDate)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "领取开始日期必须为 YYYY-MM-DD"})
		return
	}
	end, err := parseAPICheckInDate(input.ClaimEndDate)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "领取结束日期必须为 YYYY-MM-DD"})
		return
	}
	targets := make([]services.CheckInCompensationTarget, 0, len(input.Targets))
	for _, target := range input.Targets {
		date, err := parseAPICheckInDate(target.CheckInDate)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "补偿签到日期必须为 YYYY-MM-DD"})
			return
		}
		targets = append(targets, services.CheckInCompensationTarget{
			UserID: target.UserID, CheckInDate: date, ExpReward: target.ExpReward, Reason: strings.TrimSpace(target.Reason),
		})
	}
	now, err := shanghaiNow()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "系统时区配置错误"})
		return
	}
	campaign, err := h.service.PublishCampaign(services.CheckInCompensationCampaignInput{
		Title: input.Title, Description: input.Description, ClaimStartDate: start, ClaimEndDate: end, CreatedBy: operatorID, Targets: targets,
	}, now)
	if err != nil {
		writeCompensationError(c, err, "发布补偿活动失败")
		return
	}
	c.JSON(http.StatusCreated, campaignResponse(campaign))
}

// ListMine 返回当前用户被快照到的补偿资格和领取状态。
func (h *CheckInCompensationHandler) ListMine(c *gin.Context) {
	items, err := h.service.ListForUser(c.GetUint("user_id"))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取补偿活动失败"})
		return
	}
	response := make([]gin.H, 0, len(items))
	for _, item := range items {
		entry := gin.H{
			"campaign_id":      item.CampaignID,
			"title":            item.CampaignTitle,
			"description":      item.Description,
			"status":           item.CampaignStatus,
			"claim_start_date": services.FormatCheckInDate(item.ClaimStartDate),
			"claim_end_date":   services.FormatCheckInDate(item.ClaimEndDate),
			"check_in_date":    services.FormatCheckInDate(item.CheckInDate),
			"exp_reward":       item.ExpReward,
			"reason":           item.Reason,
			"claimed":          item.Claimed,
		}
		if item.ClaimedAt != nil {
			entry["claimed_at"] = item.ClaimedAt.Format(time.RFC3339)
		}
		response = append(response, entry)
	}
	c.JSON(http.StatusOK, response)
}

type claimCheckInCompensationInput struct {
	CheckInDate string `json:"check_in_date" binding:"required"`
}

// Claim 按补偿日期领取。多日活动需要逐日调用，所有调用都是幂等的。
func (h *CheckInCompensationHandler) Claim(c *gin.Context) {
	campaignID, err := parsePositiveUint(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的活动ID"})
		return
	}
	var input claimCheckInCompensationInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "补偿领取参数无效"})
		return
	}
	date, err := parseAPICheckInDate(input.CheckInDate)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "补偿签到日期必须为 YYYY-MM-DD"})
		return
	}
	now, err := shanghaiNow()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "系统时区配置错误"})
		return
	}
	result, err := h.service.Claim(c.GetUint("user_id"), campaignID, date, now)
	if err != nil {
		writeCompensationError(c, err, "领取签到补偿失败")
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"success":       true,
		"already":       result.Already,
		"check_in_date": services.FormatCheckInDate(date),
		"exp_earned":    result.ExpReward,
		"total_exp":     result.TotalExp,
	})
}

// ListCampaigns 供运营核对活动、资格和领取总数。
func (h *CheckInCompensationHandler) ListCampaigns(c *gin.Context) {
	var campaigns []models.CheckInCompensationCampaign
	if err := h.db.Order("created_at DESC").Find(&campaigns).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取补偿活动失败"})
		return
	}
	response := make([]gin.H, 0, len(campaigns))
	for _, campaign := range campaigns {
		var eligibilityCount, claimCount int64
		if err := h.db.Model(&models.CheckInCompensationEligibility{}).Where("campaign_id = ?", campaign.ID).Count(&eligibilityCount).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "读取补偿资格失败"})
			return
		}
		if err := h.db.Model(&models.CheckInCompensationClaim{}).Where("campaign_id = ?", campaign.ID).Count(&claimCount).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "读取补偿领取流水失败"})
			return
		}
		entry := campaignResponse(campaign)
		entry["eligibility_count"] = eligibilityCount
		entry["claim_count"] = claimCount
		response = append(response, entry)
	}
	c.JSON(http.StatusOK, response)
}

// Close 关闭活动后不删除资格快照和领取流水。
func (h *CheckInCompensationHandler) Close(c *gin.Context) {
	campaignID, err := parsePositiveUint(c.Param("id"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的活动ID"})
		return
	}
	if err := h.service.CloseCampaign(campaignID); err != nil {
		writeCompensationError(c, err, "关闭补偿活动失败")
		return
	}
	c.JSON(http.StatusOK, gin.H{"success": true})
}

func campaignResponse(campaign models.CheckInCompensationCampaign) gin.H {
	return gin.H{
		"id":               campaign.ID,
		"title":            campaign.Title,
		"description":      campaign.Description,
		"status":           campaign.Status,
		"claim_start_date": services.FormatCheckInDate(campaign.ClaimStartDate),
		"claim_end_date":   services.FormatCheckInDate(campaign.ClaimEndDate),
		"published_at":     campaign.PublishedAt.Format(time.RFC3339),
		"created_by":       campaign.CreatedBy,
	}
}

func parseAPICheckInDate(raw string) (time.Time, error) {
	return time.Parse("2006-01-02", strings.TrimSpace(raw))
}

func parsePositiveUint(raw string) (uint, error) {
	value, err := strconv.ParseUint(raw, 10, 64)
	if err != nil || value == 0 {
		return 0, errors.New("无效正整数")
	}
	return uint(value), nil
}

func writeCompensationError(c *gin.Context, err error, fallback string) {
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"error": "补偿资格或活动不存在"})
		return
	}
	if strings.Contains(err.Error(), "不可领取") || strings.Contains(err.Error(), "资格") || strings.Contains(err.Error(), "无效") || strings.Contains(err.Error(), "长度") || strings.Contains(err.Error(), "重复") || strings.Contains(err.Error(), "不存在的用户") {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"error": fallback})
}
