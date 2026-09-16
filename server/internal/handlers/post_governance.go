package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// PostGovernanceHandler 承载治理隐藏帖子的作者整改复审链路。
type PostGovernanceHandler struct {
	db *gorm.DB
}

func NewPostGovernanceHandler(db *gorm.DB) *PostGovernanceHandler {
	return &PostGovernanceHandler{db: db}
}

// SubmitRectification 作者提交当前明确 revision 的整改复审。
func (h *PostGovernanceHandler) SubmitRectification(c *gin.Context) {
	postID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_post_id", "error": "无效的帖子ID"})
		return
	}
	userID := c.GetUint("user_id")
	var review models.PostRectificationReview
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, postID).Error; err != nil {
			return err
		}
		if post.AuthorID != userID {
			return fmt.Errorf("not_post_owner")
		}
		if post.Status != models.PostStatusModeratedHidden {
			return fmt.Errorf("post_not_moderated")
		}
		if post.Revision < 1 {
			post.Revision = 1
		}
		var pending int64
		if err := tx.Model(&models.PostRectificationReview{}).
			Where("post_id = ? AND status = ?", post.ID, models.RectificationReviewPending).
			Count(&pending).Error; err != nil {
			return err
		}
		if pending > 0 {
			return fmt.Errorf("rectification_already_pending")
		}
		var report models.Report
		_ = tx.Where("target_type = ? AND target_id = ? AND action = ?", "post", post.ID, models.ReportActionModeratedHidden).
			Order("handled_at DESC").First(&report).Error
		review = models.PostRectificationReview{
			PostID: post.ID, SubmittedRevision: post.Revision,
			Status: models.RectificationReviewPending,
		}
		if report.ID > 0 {
			review.ReportID = &report.ID
		}
		return tx.Create(&review).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"code": "post_not_found", "error": "帖子不存在"})
		case err.Error() == "not_post_owner":
			c.JSON(http.StatusForbidden, gin.H{"code": "not_post_owner", "error": "只有作者可以提交整改复审"})
		case err.Error() == "post_not_moderated":
			c.JSON(http.StatusConflict, gin.H{"code": "post_not_moderated", "error": "帖子当前不在治理隐藏状态"})
		case err.Error() == "rectification_already_pending":
			c.JSON(http.StatusConflict, gin.H{"code": "rectification_already_pending", "error": "该帖子已有待处理的整改复审"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "提交整改复审失败"})
		}
		return
	}
	c.JSON(http.StatusCreated, review)
}

// ListRectification 管理员查看整改待办。
func (h *PostGovernanceHandler) ListRectification(c *gin.Context) {
	status := c.DefaultQuery("status", string(models.RectificationReviewPending))
	var reviews []models.PostRectificationReview
	if err := h.db.Where("status = ?", status).Preload("Post").Order("created_at ASC").Find(&reviews).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取整改复审失败"})
		return
	}
	c.JSON(http.StatusOK, reviews)
}

// ResolveRectification 由管理员通过或驳回整改复审。
func (h *PostGovernanceHandler) ResolveRectification(c *gin.Context) {
	reviewID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的整改复审ID"})
		return
	}
	decision := strings.ToLower(strings.TrimSpace(c.Param("decision")))
	if decision != "approve" && decision != "reject" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "decision 必须是 approve 或 reject"})
		return
	}
	var input struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写审核理由"})
		return
	}
	reviewerID := c.GetUint("user_id")
	var review models.PostRectificationReview
	var authorID, postID uint
	err = h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Preload("Post").First(&review, reviewID).Error; err != nil {
			return err
		}
		if review.Status != models.RectificationReviewPending {
			return fmt.Errorf("review_already_resolved")
		}
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, review.PostID).Error; err != nil {
			return err
		}
		if post.Status != models.PostStatusModeratedHidden || post.Revision != review.SubmittedRevision {
			return fmt.Errorf("content_revision_changed")
		}
		now := time.Now()
		review.ReviewerID = &reviewerID
		review.ReviewReason = input.Reason
		review.ReviewedAt = &now
		if decision == "approve" {
			review.Status = models.RectificationReviewApproved
			if err := tx.Model(&post).Update("status", models.PostStatusNormal).Error; err != nil {
				return err
			}
			var rows []models.PostImage
			if err := tx.Select("file_id").Where("post_id = ?", post.ID).Find(&rows).Error; err == nil && len(rows) > 0 {
				fileIDs := make([]uint, 0, len(rows))
				for _, r := range rows {
					fileIDs = append(fileIDs, r.FileID)
				}
				if err := services.ReconcileFilePublicAccess(tx, fileIDs...); err != nil {
					return err
				}
			}
		} else {
			review.Status = models.RectificationReviewRejected
		}
		if err := tx.Save(&review).Error; err != nil {
			return err
		}
		authorID, postID = post.AuthorID, post.ID
		return tx.Create(&models.AdminActionLog{AdminID: reviewerID, Action: "resolve_rectification", TargetType: "post_rectification_review", TargetID: review.ID, Detail: input.Reason}).Error
	})
	if err != nil {
		switch err.Error() {
		case "review_already_resolved":
			c.JSON(http.StatusConflict, gin.H{"code": "review_already_resolved", "error": "整改复审已处理"})
		case "content_revision_changed":
			c.JSON(http.StatusConflict, gin.H{"code": "content_revision_changed", "error": "作者在审核期间修改了内容，请重新检查最新版本"})
		default:
			if errors.Is(err, gorm.ErrRecordNotFound) {
				c.JSON(http.StatusNotFound, gin.H{"error": "整改复审不存在"})
			} else {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "处理整改复审失败"})
			}
		}
		return
	}
	if decision == "approve" {
		_ = CreatePostModerationResultNotification(h.db, authorID, postID, models.NotificationTypeRectificationApproved, "你修改后的帖子已通过整改复审，现已恢复公开展示。", fmt.Sprintf("rectification-approved:%d", review.ID))
	} else {
		_ = CreatePostModerationResultNotification(h.db, authorID, postID, models.NotificationTypeRectificationRejected, "整改复审未通过："+input.Reason+"。你可以继续修改后再次提交。", fmt.Sprintf("rectification-rejected:%d", review.ID))
	}
	c.JSON(http.StatusOK, review)
}

// AdminRestorePost 人工纠正治理误操作，恢复帖子公开展示并生成审计日志。
func (h *PostGovernanceHandler) AdminRestorePost(c *gin.Context) {
	postID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_post_id", "error": "无效的帖子ID"})
		return
	}
	var input struct {
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写恢复原因"})
		return
	}
	reviewerID := c.GetUint("user_id")

	var authorID uint
	var fileIDs []uint
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, postID).Error; err != nil {
			return err
		}
		if post.Status != models.PostStatusModeratedHidden {
			return fmt.Errorf("post_not_moderated")
		}
		now := time.Now()
		if err := tx.Model(&post).Updates(map[string]interface{}{
			"status":               models.PostStatusNormal,
			"moderation_rule_code": "",
			"moderation_reason":   "",
		}).Error; err != nil {
			return err
		}
		// 关闭未决的整改复审
		_ = tx.Model(&models.PostRectificationReview{}).
			Where("post_id = ? AND status = ?", post.ID, models.RectificationReviewPending).
			Updates(map[string]interface{}{
				"status":        models.RectificationReviewApproved,
				"reviewer_id":   reviewerID,
				"review_reason": input.Reason,
				"reviewed_at":   &now,
			}).Error

		authorID = post.AuthorID

		var rows []models.PostImage
		if err := tx.Select("file_id").Where("post_id = ?", post.ID).Find(&rows).Error; err == nil {
			for _, r := range rows {
				fileIDs = append(fileIDs, r.FileID)
			}
		}
		if len(fileIDs) > 0 {
			if err := services.ReconcileFilePublicAccess(tx, fileIDs...); err != nil {
				return err
			}
		}
		return tx.Create(&models.AdminActionLog{
			AdminID:    reviewerID,
			Action:     "restore_post",
			TargetType: "post",
			TargetID:   post.ID,
			Detail:     fmt.Sprintf("恢复帖子公开展示: %s", input.Reason),
		}).Error
	})
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		case err.Error() == "post_not_moderated":
			c.JSON(http.StatusConflict, gin.H{"code": "post_not_moderated", "error": "帖子当前不在治理限制状态"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复帖子失败"})
		}
		return
	}
	_ = CreatePostModerationResultNotification(
		h.db, authorID, uint(postID),
		models.NotificationTypeRectificationApproved,
		"你的帖子已由管理员恢复正常公开展示。说明："+input.Reason,
		fmt.Sprintf("admin-restored:%d:%d", postID, time.Now().Unix()),
	)
	c.JSON(http.StatusOK, gin.H{"message": "帖子已恢复公开展示"})
}

