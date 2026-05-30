package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

// ReportHandler 举报处理器
type ReportHandler struct {
	db *gorm.DB
}

// NewReportHandler 创建举报处理器
func NewReportHandler(db *gorm.DB) *ReportHandler {
	return &ReportHandler{db: db}
}

// CreateReportInput 创建举报输入
type CreateReportInput struct {
	TargetType string `json:"target_type" binding:"required"` // post/reply
	TargetID   uint   `json:"target_id" binding:"required"`
	Reason     string `json:"reason" binding:"required"`
}

// Create 创建举报
func (h *ReportHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")

	var input CreateReportInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	report := models.Report{
		ReporterID: userID.(uint),
		TargetType: input.TargetType,
		TargetID:   input.TargetID,
		Reason:     input.Reason,
		Status:     models.ReportStatusPending,
	}

	if err := h.db.Create(&report).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建举报失败"})
		return
	}

	c.JSON(http.StatusCreated, report)
}

// GetList 获取举报列表（仅管理员）
func (h *ReportHandler) GetList(c *gin.Context) {
	status := c.Query("status")

	query := h.db.Model(&models.Report{}).Preload("Reporter").Preload("Handler")
	if status != "" {
		query = query.Where("status = ?", status)
	}
	query.Order("created_at DESC")

	var reports []models.Report
	query.Find(&reports)

	c.JSON(http.StatusOK, reports)
}

// HandleReportInput 处理举报输入
type HandleReportInput struct {
	Status       string `json:"status" binding:"required"` // handled/ignored
	Result       string `json:"result"`
	DeleteReason string `json:"delete_reason"`
}

// Handle 处理举报
func (h *ReportHandler) Handle(c *gin.Context) {
	userID, _ := c.Get("user_id")
	reportIDStr := c.Param("id")
	reportID, err := strconv.ParseUint(reportIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的举报ID"})
		return
	}

	var input HandleReportInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var report models.Report
	if err := h.db.First(&report, reportID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "举报不存在"})
		return
	}

	now := time.Now()
	report.Status = models.ReportStatus(input.Status)
	report.HandlerID = new(uint)
	*report.HandlerID = userID.(uint)
	report.Result = input.Result
	report.DeleteReason = input.DeleteReason
	report.HandledAt = &now

	h.db.Save(&report)

	// 如果是处理举报且理由是删除，则删除内容并允许申诉
	if input.Status == "handled" && input.DeleteReason != "" {
		if report.TargetType == "post" {
			h.db.Model(&models.Post{}).Where("id = ?", report.TargetID).Update("status", models.PostStatusDeleted)

			// 创建申诉记录
			var post models.Post
			h.db.First(&post, report.TargetID)

			appeal := models.Appeal{
				PostID:      report.TargetID,
				AppellantID: post.AuthorID,
				AdminID:     userID.(uint),
				AdminReason: input.DeleteReason,
				Status:      models.AppealStatusPending,
			}
			h.db.Create(&appeal)
		} else if report.TargetType == "reply" {
			h.db.Model(&models.Reply{}).Where("id = ?", report.TargetID).Update("status", models.ReplyStatusDeleted)
		}

		// 更新被举报者的举报计数
		var targetUserID uint
		if report.TargetType == "post" {
			var post models.Post
			if h.db.First(&post, report.TargetID) == nil {
				targetUserID = post.AuthorID
			}
		} else if report.TargetType == "reply" {
			var reply models.Reply
			if h.db.First(&reply, report.TargetID) == nil {
				targetUserID = reply.AuthorID
			}
		}
		if targetUserID > 0 {
			h.db.Model(&models.User{}).Where("id = ?", targetUserID).Update("report_count", gorm.Expr("report_count + 1"))
		}
	}

	// 记录管理员操作
	log := models.AdminActionLog{
		AdminID:    userID.(uint),
		Action:     "handle_report",
		TargetType: "report",
		TargetID:   uint(reportID),
		Detail:     fmt.Sprintf("处理举报: %s, 结果: %s", report.Reason, input.Status),
	}
	h.db.Create(&log)

	// 管理员处理举报，经验+1
	h.db.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1"))

	c.JSON(http.StatusOK, report)
}
