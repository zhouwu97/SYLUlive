package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
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
	studentID := c.Query("student_id")

	query := h.db.Model(&models.User{}).
		Where("report_count = 0 AND credit_score > 90 AND role = ?", models.RoleUser)

	if studentID != "" {
		query = query.Where("student_id LIKE ?", "%"+studentID+"%")
	}

	var candidates []models.User
	query.Order("credit_score DESC").Find(&candidates)
	c.JSON(http.StatusOK, candidates)
}

// GetMembers 获取所有管理员列表
func (h *InvitationHandler) GetMembers(c *gin.Context) {
	var members []models.User
	if err := h.db.Where("role IN ?", []string{"admin", "super_admin"}).Select("id, nickname, student_id, role").Find(&members).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取管理员列表失败"})
		return
	}
	c.JSON(http.StatusOK, members)
}

// DirectPromote 超管直接提升为管理员
func (h *InvitationHandler) DirectPromote(c *gin.Context) {
	var input struct {
		UserID uint `json:"user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	var user models.User
	if h.db.First(&user, input.UserID).Error != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	if user.Role != models.RoleUser {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该用户已是管理员"})
		return
	}
	h.db.Model(&user).Update("role", models.RoleAdmin)

	// 记录日志
	adminID, _ := c.Get("user_id")
	var admin models.User
	h.db.Select("nickname").First(&admin, adminID)
	h.db.Create(&models.AdminLog{AdminID: adminID.(uint), AdminName: admin.Nickname, Action: "直接提升管理员", Target: user.Nickname, Detail: user.StudentID})

	c.JSON(http.StatusOK, gin.H{"message": user.Nickname + " 已成为管理员"})
}

// CreateInvitation 创建邀请
func (h *InvitationHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input struct {
		Reason string `json:"reason" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || strings.TrimSpace(input.Reason) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写邀请理由"})
		return
	}

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
	if h.db.Where("user_id = ? AND status IN ?", targetUserID, []models.InvitationStatus{
		models.InvitationStatusPending,
		models.InvitationStatusAccepted,
	}).First(&existing).Error == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "已有待处理的邀请"})
		return
	}

	invitation := models.Invitation{
		UserID:    uint(targetUserID),
		InviterID: userID.(uint),
		Reason:    strings.TrimSpace(input.Reason),
		Status:    models.InvitationStatusPending,
	}

	if err := h.db.Create(&invitation).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建邀请失败"})
		return
	}

	// 记录日志
	adminID, _ := c.Get("user_id")
	var admin models.User
	h.db.Select("nickname").First(&admin, adminID)
	h.db.Create(&models.AdminLog{AdminID: adminID.(uint), AdminName: admin.Nickname, Action: "邀请管理员", Target: user.Nickname, Detail: strings.TrimSpace(input.Reason)})

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
	if err := h.db.Preload("Inviter").Preload("User").First(&invitation, invitationID).Error; err != nil {
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

	acceptedAt := time.Now()
	if err := h.db.Model(&invitation).Updates(map[string]interface{}{
		"status":      models.InvitationStatusAccepted,
		"accepted_at": acceptedAt,
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "接受邀请失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已同意邀请，等待 3 名管理员审批"})
}

// Approve 超级管理员批准邀请
func (h *InvitationHandler) Approve(c *gin.Context) {
	var input struct {
		Reject bool   `json:"reject"`
		Reason string `json:"reason"`
	}
	_ = c.ShouldBindJSON(&input)

	invitationIDStr := c.Param("id")
	invitationID, err := strconv.ParseUint(invitationIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的邀请ID"})
		return
	}

	var invitation models.Invitation
	if err := h.db.Preload("User").First(&invitation, invitationID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "邀请不存在"})
		return
	}

	if invitation.Status != models.InvitationStatusAccepted {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该邀请未被接受"})
		return
	}

	if input.Reject {
		h.db.Model(&invitation).Update("status", models.InvitationStatusRejected)
		c.JSON(http.StatusOK, gin.H{"message": "已驳回管理员邀请"})
		return
	}

	h.voteInvitation(c, invitation, strings.TrimSpace(input.Reason))
}

// GetApprovalList 获取待批准的邀请（超管用）
func (h *InvitationHandler) GetApprovalList(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var invitations []models.Invitation
	if err := h.db.Where("status = ?", models.InvitationStatusAccepted).
		Preload("User").Preload("Inviter").Order("accepted_at ASC").Find(&invitations).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取管理员邀请待办失败"})
		return
	}

	result := make([]gin.H, 0, len(invitations))
	for _, invitation := range invitations {
		var votes int64
		h.db.Model(&models.InvitationVote{}).Where("invitation_id = ?", invitation.ID).Count(&votes)
		var myVote int64
		h.db.Model(&models.InvitationVote{}).Where("invitation_id = ? AND voter_id = ?", invitation.ID, userID).Count(&myVote)
		result = append(result, gin.H{
			"id":             invitation.ID,
			"user_id":        invitation.UserID,
			"inviter_id":     invitation.InviterID,
			"reason":         invitation.Reason,
			"status":         invitation.Status,
			"created_at":     invitation.CreatedAt,
			"accepted_at":    invitation.AcceptedAt,
			"user":           invitation.User,
			"inviter":        invitation.Inviter,
			"votes":          votes,
			"required_votes": 3,
			"my_vote":        myVote > 0,
		})
	}

	c.JSON(http.StatusOK, result)
}

// VoteApprove 管理员同意邀请，累计 3 票后用户成为管理员。
func (h *InvitationHandler) VoteApprove(c *gin.Context) {
	var input struct {
		Reason string `json:"reason" binding:"required"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || strings.TrimSpace(input.Reason) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写审批理由"})
		return
	}

	invitationID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的邀请ID"})
		return
	}

	var invitation models.Invitation
	if err := h.db.Preload("User").First(&invitation, invitationID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "邀请不存在"})
		return
	}
	h.voteInvitation(c, invitation, strings.TrimSpace(input.Reason))
}

func (h *InvitationHandler) voteInvitation(c *gin.Context, invitation models.Invitation, reason string) {
	if invitation.Status != models.InvitationStatusAccepted {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该邀请未进入管理员代办"})
		return
	}
	if reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写审批理由"})
		return
	}

	userID, _ := c.Get("user_id")
	voterID := userID.(uint)
	if voterID == invitation.UserID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能审批自己的管理员邀请"})
		return
	}

	vote := models.InvitationVote{InvitationID: invitation.ID, VoterID: voterID, Reason: reason}
	if err := h.db.Create(&vote).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "你已经审批过该邀请"})
		return
	}

	var votes int64
	h.db.Model(&models.InvitationVote{}).Where("invitation_id = ?", invitation.ID).Count(&votes)
	if votes >= 3 {
		if err := h.db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Model(&models.Invitation{}).Where("id = ?", invitation.ID).Update("status", models.InvitationStatusApproved).Error; err != nil {
				return err
			}
			return tx.Model(&models.User{}).Where("id = ?", invitation.UserID).Update("role", models.RoleAdmin).Error
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "审批失败"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("已满 3 票，%s 已成为管理员", invitation.User.Nickname), "votes": votes, "required_votes": 3})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": fmt.Sprintf("已同意，还需 %d 票", 3-votes), "votes": votes, "required_votes": 3})
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
