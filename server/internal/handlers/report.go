package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
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
	TargetType string `json:"target_type" binding:"required"` // post/reply/teacher_rating/major_rating
	TargetID   uint   `json:"target_id" binding:"required"`
	ReasonCode string `json:"reason_code"`
	Reason     string `json:"reason" binding:"required"`
}

type reportCreateError struct {
	status  int
	code    string
	message string
}

func (e *reportCreateError) Error() string { return e.message }

// Create 创建举报
func (h *ReportHandler) Create(c *gin.Context) {
	userID := c.GetUint("user_id")

	var input CreateReportInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	report, err := createReport(h.db, userID, input)
	if err != nil {
		writeReportCreateError(c, err)
		return
	}
	c.JSON(http.StatusCreated, report)
}

// createReport 是统一举报写入逻辑，供新接口和旧兼容接口共同使用。
// 兼容接口只负责解析 HTTP 输入，不直接调用另一个 Gin Handler。
func createReport(db *gorm.DB, userID uint, input CreateReportInput) (models.Report, error) {
	if input.TargetType != "post" && input.TargetType != "reply" && input.TargetType != "teacher_rating" && input.TargetType != "major_rating" {
		return models.Report{}, &reportCreateError{status: http.StatusBadRequest, code: "invalid_target_type", message: "不支持的 target_type"}
	}
	if reasonLength := len([]rune(strings.TrimSpace(input.Reason))); reasonLength < 2 || reasonLength > 500 {
		return models.Report{}, &reportCreateError{status: http.StatusBadRequest, code: "invalid_report_reason", message: "举报理由长度需在 2 到 500 个字符之间"}
	}
	var targetOwner uint
	var snapshot string

	switch input.TargetType {
	case "post":
		var post models.Post
		if err := db.Select("author_id", "status").First(&post, input.TargetID).Error; err != nil || post.Status == models.PostStatusDeleted {
			return models.Report{}, &reportCreateError{status: http.StatusNotFound, code: "target_not_found", message: "帖子不存在或已删除"}
		}
		targetOwner = post.AuthorID
	case "reply":
		var reply models.Reply
		if err := db.Select("author_id", "status").First(&reply, input.TargetID).Error; err != nil || reply.Status != models.ReplyStatusNormal {
			return models.Report{}, &reportCreateError{status: http.StatusNotFound, code: "target_not_found", message: "回复不存在或已删除"}
		}
		targetOwner = reply.AuthorID
	case "teacher_rating":
		var tr models.TeacherRating
		if err := db.First(&tr, input.TargetID).Error; err != nil || tr.Status != "normal" || tr.DeletedAt.Valid {
			return models.Report{}, &reportCreateError{status: http.StatusNotFound, code: "target_not_found", message: "评价不存在或已删除"}
		}
		targetOwner = tr.UserID
		payload, err := json.Marshal(gin.H{"star": tr.Star, "comment": tr.Comment})
		if err != nil {
			return models.Report{}, err
		}
		snapshot = string(payload)
	case "major_rating":
		var mr models.MajorRating
		if err := db.First(&mr, input.TargetID).Error; err != nil || mr.Status != "normal" || mr.DeletedAt.Valid {
			return models.Report{}, &reportCreateError{status: http.StatusNotFound, code: "target_not_found", message: "评价不存在或已删除"}
		}
		targetOwner = mr.UserID
		payload, err := json.Marshal(gin.H{"star": mr.Star, "comment": mr.Comment})
		if err != nil {
			return models.Report{}, err
		}
		snapshot = string(payload)
	}
	if targetOwner == userID {
		return models.Report{}, &reportCreateError{status: http.StatusBadRequest, code: "self_report_forbidden", message: "不能举报自己的内容"}
	}
	var existing models.Report
	if err := db.Where("reporter_id = ? AND target_type = ? AND target_id = ? AND status = ?", userID, input.TargetType, input.TargetID, models.ReportStatusPending).First(&existing).Error; err == nil {
		return models.Report{}, &reportCreateError{status: http.StatusConflict, code: "report_already_pending", message: "请勿重复举报"}
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return models.Report{}, err
	}

	report := models.Report{
		ReporterID:     userID,
		TargetType:     input.TargetType,
		TargetID:       input.TargetID,
		ReasonCode:     input.ReasonCode,
		Reason:         input.Reason,
		TargetAuthorID: &targetOwner,
		TargetSnapshot: snapshot,
		Status:         models.ReportStatusPending,
	}

	if err := db.Create(&report).Error; err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "uq_pending_report_target") {
			return models.Report{}, &reportCreateError{status: http.StatusConflict, code: "report_already_pending", message: "请勿重复举报"}
		}
		return models.Report{}, err
	}
	return report, nil
}

func writeReportCreateError(c *gin.Context, err error) {
	var createErr *reportCreateError
	if errors.As(err, &createErr) {
		c.JSON(createErr.status, gin.H{"code": createErr.code, "error": createErr.message})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"code": "report_create_failed", "error": "创建举报失败"})
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
			case "teacher_rating":
				var tr models.TeacherRating
				if err := tx.First(&tr, report.TargetID).Error; err != nil {
					return err
				}
				if err := tx.Model(&tr).Updates(map[string]interface{}{
					"status":            "hidden",
					"moderated_by":      userID.(uint),
					"moderation_reason": input.DeleteReason,
					"moderated_at":      time.Now(),
				}).Error; err != nil {
					return err
				}
				targetUserID = tr.UserID
			case "major_rating":
				var mr models.MajorRating
				if err := tx.First(&mr, report.TargetID).Error; err != nil {
					return err
				}
				if err := tx.Model(&mr).Updates(map[string]interface{}{
					"status":            "hidden",
					"moderated_by":      userID.(uint),
					"moderation_reason": input.DeleteReason,
					"moderated_at":      time.Now(),
				}).Error; err != nil {
					return err
				}
				targetUserID = mr.UserID
			default:
				return fmt.Errorf("invalid_target_type")
			}
			if err := tx.Model(&models.User{}).Where("id = ?", targetUserID).Update("report_count", gorm.Expr("report_count + 1")).Error; err != nil {
				return err
			}
			// 同一目标的其他待处理举报不能再次触发删除、计数或申诉。
			if err := tx.Model(&models.Report{}).
				Where("target_type = ? AND target_id = ? AND status = ? AND id <> ?", report.TargetType, report.TargetID, models.ReportStatusPending, report.ID).
				Updates(map[string]interface{}{
					"status":     models.ReportStatusIgnored,
					"handler_id": userID.(uint),
					"handled_at": &now,
					"result":     fmt.Sprintf("目标已通过举报 #%d 完成治理", report.ID),
				}).Error; err != nil {
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
