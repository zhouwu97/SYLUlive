package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
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
	if input.TargetType != "post" && input.TargetType != "reply" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "target_type 仅支持 post 或 reply"})
		return
	}
	if reasonLength := len([]rune(input.Reason)); reasonLength < 2 || reasonLength > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "举报理由长度需在 2 到 500 个字符之间"})
		return
	}
	var targetOwner uint
	if input.TargetType == "post" {
		var post models.Post
		if err := h.db.Select("author_id", "status").First(&post, input.TargetID).Error; err != nil || post.Status == models.PostStatusDeleted {
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在或已删除"})
			return
		}
		targetOwner = post.AuthorID
	} else {
		var reply models.Reply
		if err := h.db.Select("author_id", "status").First(&reply, input.TargetID).Error; err != nil || reply.Status != models.ReplyStatusNormal {
			c.JSON(http.StatusNotFound, gin.H{"error": "回复不存在或已删除"})
			return
		}
		targetOwner = reply.AuthorID
	}
	if targetOwner == userID.(uint) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能举报自己的内容"})
		return
	}
	var existing models.Report
	if err := h.db.Where("reporter_id = ? AND target_type = ? AND target_id = ? AND status = ?", userID, input.TargetType, input.TargetID, models.ReportStatusPending).First(&existing).Error; err == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "请勿重复举报"})
		return
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询举报状态失败"})
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
	if err := query.Find(&reports).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取举报列表失败"})
		return
	}

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

	if input.Status != string(models.ReportStatusHandled) && input.Status != string(models.ReportStatusIgnored) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "status 仅支持 handled 或 ignored"})
		return
	}
	var report models.Report
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.First(&report, reportID).Error; err != nil {
			return err
		}
		if report.Status != models.ReportStatusPending {
			return fmt.Errorf("report_already_handled")
		}
		now := time.Now()
		report.Status = models.ReportStatus(input.Status)
		report.HandlerID = new(uint)
		*report.HandlerID = userID.(uint)
		report.Result, report.DeleteReason, report.HandledAt = input.Result, input.DeleteReason, &now
		if err := tx.Save(&report).Error; err != nil {
			return err
		}

		if input.Status == string(models.ReportStatusHandled) && input.DeleteReason != "" {
			var targetUserID uint
			switch report.TargetType {
			case "post":
				var post models.Post
				if err := tx.First(&post, report.TargetID).Error; err != nil {
					return err
				}
				if err := tx.Model(&post).Update("status", models.PostStatusDeleted).Error; err != nil {
					return err
				}
				targetUserID = post.AuthorID
				deadline := now.Add(72 * time.Hour)
				appeal := models.Appeal{PostID: post.ID, AppellantID: post.AuthorID, AdminID: userID.(uint), AdminReason: input.DeleteReason, Status: models.AppealStatusPending, VotingDeadline: &deadline}
				if err := tx.Create(&appeal).Error; err != nil {
					return err
				}
				if err := NewAppealHandler(tx).selectJury(appeal.ID, post.AuthorID, userID.(uint)); err != nil {
					return err
				}
			case "reply":
				var reply models.Reply
				if err := tx.First(&reply, report.TargetID).Error; err != nil {
					return err
				}
				if err := tx.Model(&reply).Update("status", models.ReplyStatusDeleted).Error; err != nil {
					return err
				}
				if err := recalculatePostReplyStats(tx, reply.PostID); err != nil {
					return err
				}
				targetUserID = reply.AuthorID
			default:
				return fmt.Errorf("invalid_target_type")
			}
			if err := tx.Model(&models.User{}).Where("id = ?", targetUserID).Update("report_count", gorm.Expr("report_count + 1")).Error; err != nil {
				return err
			}
		}
		if err := tx.Create(&models.AdminActionLog{AdminID: userID.(uint), Action: "handle_report", TargetType: "report", TargetID: uint(reportID), Detail: fmt.Sprintf("处理举报: %s, 结果: %s", report.Reason, input.Status)}).Error; err != nil {
			return err
		}
		return tx.Model(&models.User{}).Where("id = ?", userID).UpdateColumn("admin_exp", gorm.Expr("COALESCE(admin_exp, 0) + 1")).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "举报或目标内容不存在"})
		case err.Error() == "report_already_handled":
			c.JSON(http.StatusConflict, gin.H{"error": "举报已处理，请勿重复提交"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "处理举报失败"})
		}
		return
	}
	c.JSON(http.StatusOK, report)
}
