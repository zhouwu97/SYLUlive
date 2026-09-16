package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"os"
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
	db        *gorm.DB
	uploadDir string
}

func NewPostGovernanceHandler(db *gorm.DB) *PostGovernanceHandler {
	return &PostGovernanceHandler{db: db}
}

func (h *PostGovernanceHandler) SetUploadDir(dir string) {
	h.uploadDir = dir
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
//
// 返回的每一项都必须能回答两个问题，否则管理员只能“看现在这篇挺正常就点通过”，
// 并不知道作者改掉了什么：
//   - 当初为什么被处理（治理规则码 + 管理员处理说明）；
//   - 处理时是哪一版、内容长什么样（vs 现在提交的整改版本）。
func (h *PostGovernanceHandler) ListRectification(c *gin.Context) {
	status := c.DefaultQuery("status", string(models.RectificationReviewPending))
	var reviews []models.PostRectificationReview
	if err := h.db.Where("status = ?", status).
		Preload("Post.Images.File").Preload("Report").
		Order("created_at ASC").Find(&reviews).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取整改复审失败"})
		return
	}
	items := make([]rectificationAdminItem, 0, len(reviews))
	for i := range reviews {
		items = append(items, h.buildRectificationAdminItem(&reviews[i]))
	}
	c.JSON(http.StatusOK, items)
}

// rectificationAdminItem 是管理端整改待办卡片所需的完整审核上下文。
//
// 单独定义响应结构体、不复用 models.Report：举报人身份（reporter_id、举报人自述）
// 不属于审核依据，不能搭着整改待办一起下发。
type rectificationAdminItem struct {
	models.PostRectificationReview
	// OriginalRuleCode / OriginalReason 取自帖子当前记录的治理依据。整改待办只在
	// moderated_hidden 期间存在，而这两个字段在恢复公开时会被清空，窗口正好吻合。
	OriginalRuleCode string `json:"original_rule_code,omitempty"`
	OriginalReason   string `json:"original_reason,omitempty"`
	// ReportReasonCode 是举报分类码，只给管理员做归类参考，不含举报人身份。
	ReportReasonCode  string     `json:"report_reason_code,omitempty"`
	ModeratedRevision int        `json:"moderated_revision,omitempty"`
	ModeratedSnapshot string     `json:"moderated_snapshot,omitempty"`
	ModeratedAt       *time.Time `json:"moderated_at,omitempty"`
}

// buildRectificationAdminItem 补齐治理上下文。
//
// 举报记录缺失（历史数据、或提交整改时恰好查不到治理记录）时不报错，退回按帖子
// 回查最近一次治理隐藏；仍查不到就只下发帖子字段，卡片降级展示而非整体失败。
func (h *PostGovernanceHandler) buildRectificationAdminItem(
	review *models.PostRectificationReview,
) rectificationAdminItem {
	item := rectificationAdminItem{
		PostRectificationReview: *review,
		OriginalRuleCode:        review.Post.ModerationRuleCode,
		OriginalReason:          review.Post.ModerationReason,
		ModeratedAt:             review.Post.ModeratedAt,
	}
	report := review.Report
	if report == nil {
		var fallback models.Report
		if err := h.db.
			Where("target_type = ? AND target_id = ? AND action = ?",
				"post", review.PostID, models.ReportActionModeratedHidden).
			Order("handled_at DESC").First(&fallback).Error; err == nil {
			report = &fallback
		}
	}
	if report == nil {
		return item
	}
	item.ReportReasonCode = report.ReasonCode
	item.ModeratedRevision = report.ModeratedRevision
	item.ModeratedSnapshot = report.TargetSnapshot
	if item.ModeratedAt == nil && report.HandledAt != nil {
		item.ModeratedAt = report.HandledAt
	}
	if item.OriginalReason == "" {
		item.OriginalReason = report.DeleteReason
	}
	return item
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

	// 结论通知在事务内写入，键用 reviewID 保证重试幂等（见下方 tx 内调用）。
	var (
		resultType    string
		resultContent string
		resultDedup   string
	)
	if decision == "approve" {
		resultType = models.NotificationTypeRectificationApproved
		resultContent = "你修改后的帖子已通过整改复审，现已恢复公开展示。"
		resultDedup = fmt.Sprintf("rectification-approved:%d", reviewID)
	} else {
		resultType = models.NotificationTypeRectificationRejected
		resultContent = "整改复审未通过：" + input.Reason + "。你可以继续修改后再次提交。"
		resultDedup = fmt.Sprintf("rectification-rejected:%d", reviewID)
	}

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
			if err := tx.Model(&post).Updates(map[string]interface{}{
				"status":               models.PostStatusNormal,
				"moderation_rule_code": "",
				"moderation_reason":   "",
			}).Error; err != nil {
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
		authorID, postID := post.AuthorID, post.ID
		// 站内通知必须与状态变更原子：事务外 `_ = Create...` 会让“帖子已恢复、
		// 作者永远收不到通知”静默发生，而接口照样返回成功。通知本身是幂等写入
		// （dedupKey + ON CONFLICT DO NOTHING），放进事务不会造成重复提醒。
		if err := CreatePostModerationResultNotification(
			tx, authorID, postID, resultType, resultContent, resultDedup,
		); err != nil {
			return err
		}
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
		if err := tx.Model(&models.PostRectificationReview{}).
			Where("post_id = ? AND status = ?", post.ID, models.RectificationReviewPending).
			Updates(map[string]interface{}{
				"status":        models.RectificationReviewApproved,
				"reviewer_id":   reviewerID,
				"review_reason": input.Reason,
				"reviewed_at":   &now,
			}).Error; err != nil {
			return err
		}

		// 关闭未决的申诉
		var appeals []models.Appeal
		if err := tx.Where("post_id = ? AND status IN ?", post.ID, []models.AppealStatus{models.AppealStatusPending, models.AppealStatusReview}).Find(&appeals).Error; err != nil {
			return err
		}
		for _, ap := range appeals {
			if err := tx.Model(&ap).Updates(map[string]interface{}{
				"status":         models.AppealStatusPass,
				"result":         "管理员人工恢复帖子，申诉自动通过并结案: " + input.Reason,
				"closed_at":      &now,
				"closed_reason":  "admin_restore",
				"reviewed_by_id": &reviewerID,
			}).Error; err != nil {
				return err
			}
		}

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
		// 与整改复审通过同一条可靠性约束：站内通知落在治理事务内，不允许
		// “帖子已恢复但作者没收到通知”静默发生。
		if err := CreatePostModerationResultNotification(
			tx, authorID, post.ID,
			models.NotificationTypeRectificationApproved,
			"你的帖子已由管理员恢复正常公开展示。说明："+input.Reason,
			fmt.Sprintf("admin-restored:%d:%d", post.ID, now.Unix()),
		); err != nil {
			return err
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
	c.JSON(http.StatusOK, gin.H{"message": "帖子已恢复公开展示"})
}

// ServeGovernedEvidenceFile 供管理员安全查看违规治理凭据或快照原图。
// 必须具备 admin / super_admin 权限，禁止匿名访问。
func (h *PostGovernanceHandler) ServeGovernedEvidenceFile(c *gin.Context) {
	fileID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || fileID == 0 {
		c.Status(http.StatusNotFound)
		return
	}

	var file models.File
	if err := h.db.First(&file, fileID).Error; err != nil {
		c.Status(http.StatusNotFound)
		return
	}

	absPath, err := services.ResolveUploadPath(h.uploadDir, file.Path)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	if _, err := os.Stat(absPath); err != nil {
		c.Status(http.StatusNotFound)
		return
	}

	mimeType := file.MimeType
	if mimeType == "" {
		mimeType = "application/octet-stream"
	}
	c.Header("Content-Type", mimeType)
	c.Header("Cache-Control", "private, no-cache")
	c.Header("X-Content-Type-Options", "nosniff")
	c.File(absPath)
}
