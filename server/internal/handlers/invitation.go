package handlers

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"xiaoyuan/internal/models"
)

// InvitationHandler 邀请处理器
type InvitationHandler struct {
	db *gorm.DB
}

// NewInvitationHandler 创建邀请处理器
func NewInvitationHandler(db *gorm.DB) *InvitationHandler {
	return &InvitationHandler{db: db}
}

// GetCandidates 获取管理员候选人列表
func (h *InvitationHandler) GetCandidates(c *gin.Context) {
	var candidates []models.User
	// 近90天举报数为0且诚信度>90%
	h.db.Where("report_count = 0 AND credit_score > 90 AND role = ?", models.RoleUser).Find(&candidates)
	c.JSON(http.StatusOK, candidates)
}

// CreateInvitation 创建邀请
func (h *InvitationHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	targetUserIDStr := c.Param("user_id")
	targetUserID, err := strconv.ParseUint(targetUserIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的用户ID"})
		return
	}

	// 检查目标用户是否符合条件
	var user models.User
	if err := h.db.First(&user, targetUserID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}

	if user.Role != models.RoleUser {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只有普通用户可以受邀成为管理员"})
		return
	}

	if user.ReportCount > 0 || user.CreditScore <= 90 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该用户不符合管理员条件"})
		return
	}

	// 检查是否已有待处理的邀请
	var existing models.Invitation
	if h.db.Where("user_id = ? AND status = ?", targetUserID, models.InvitationStatusPending).First(&existing).Error == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "已有待处理的邀请"})
		return
	}

	invitation := models.Invitation{
		UserID:    uint(targetUserID),
		InviterID: userID.(uint),
		Status:    models.InvitationStatusPending,
	}

	if err := h.db.Create(&invitation).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建邀请失败"})
		return
	}

	c.JSON(http.StatusCreated, invitation)
}

// GetPending 获取当前用户的待处理邀请
func (h *InvitationHandler) GetPending(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var invitations []models.Invitation
	h.db.Where("user_id = ? AND status = ?", userID, models.InvitationStatusPending).
		Preload("Inviter").Find(&invitations)

	c.JSON(http.StatusOK, invitations)
}

// Accept 接受邀请
func (h *InvitationHandler) Accept(c *gin.Context) {
	userID, _ := c.Get("user_id")
	invitationIDStr := c.Param("id")
	invitationID, err := strconv.ParseUint(invitationIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的邀请ID"})
		return
	}

	var invitation models.Invitation
	if err := h.db.First(&invitation, invitationID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "邀请不存在"})
		return
	}

	if invitation.UserID != userID.(uint) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	if invitation.Status != models.InvitationStatusPending {
		c.JSON(http.StatusBadRequest, gin.H{"error": "邀请已处理"})
		return
	}

	h.db.Model(&invitation).Updates(map[string]interface{}{
		"status":      models.InvitationStatusAccepted,
		"accepted_at": time.Now(),
	})

	// 更新用户角色为管理员
	h.db.Model(&models.User{}).Where("id = ?", userID).Update("role", models.RoleAdmin)

	c.JSON(http.StatusOK, gin.H{"message": "已接受邀请成为管理员"})
}

// Reject 拒绝邀请
func (h *InvitationHandler) Reject(c *gin.Context) {
	userID, _ := c.Get("user_id")
	invitationIDStr := c.Param("id")
	invitationID, err := strconv.ParseUint(invitationIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的邀请ID"})
		return
	}

	var invitation models.Invitation
	if err := h.db.First(&invitation, invitationID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "邀请不存在"})
		return
	}

	if invitation.UserID != userID.(uint) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	h.db.Model(&invitation).Update("status", models.InvitationStatusRejected)

	c.JSON(http.StatusOK, gin.H{"message": "已拒绝邀请"})
}