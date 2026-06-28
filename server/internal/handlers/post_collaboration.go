package handlers

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type ownerReviewInput struct {
	Reply string `json:"reply" form:"reply"`
}

type revisionProposalInput struct {
	Title         string `json:"title" form:"title"`
	Content       string `json:"content" form:"content"`
	ChangeSummary string `json:"change_summary" form:"change_summary"`
}

func (h *PostHandler) CreateCollaborationApplication(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	postID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input applicationReasonInput
	_ = c.ShouldBind(&input)
	input.Reason = strings.TrimSpace(input.Reason)
	if input.Reason == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写共同创作申请理由"})
		return
	}
	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil || post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if !post.IsFeatured {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只有精华帖可以申请共同创作"})
		return
	}
	if post.AuthorID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能申请共同创作自己的帖子"})
		return
	}
	app := models.CollaborationApplication{
		PostID: post.ID, ApplicantID: userID, OwnerID: post.AuthorID,
		Reason: input.Reason, Status: "pending",
	}
	if err := h.db.Create(&app).Error; err != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "你已提交过待处理共同创作申请"})
		return
	}
	c.JSON(http.StatusCreated, app)
}

func (h *PostHandler) GetMyCollaborationApplicationsSent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var apps []models.CollaborationApplication
	if err := h.db.Where("applicant_id = ?", userID).
		Preload("Post").Preload("Owner").Order("created_at DESC").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取共同创作申请失败"})
		return
	}
	c.JSON(http.StatusOK, apps)
}

func (h *PostHandler) GetMyCollaborationApplicationsReceived(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var apps []models.CollaborationApplication
	if err := h.db.Where("owner_id = ?", userID).
		Preload("Post").Preload("Applicant").Order("created_at DESC").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取收到的共同创作申请失败"})
		return
	}
	c.JSON(http.StatusOK, apps)
}

func (h *PostHandler) ApproveCollaborationApplication(c *gin.Context) {
	h.reviewCollaborationApplication(c, "approved")
}

func (h *PostHandler) RejectCollaborationApplication(c *gin.Context) {
	h.reviewCollaborationApplication(c, "rejected")
}

func (h *PostHandler) reviewCollaborationApplication(c *gin.Context, status string) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	appID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input ownerReviewInput
	_ = c.ShouldBind(&input)
	now := time.Now()
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var app models.CollaborationApplication
		if err := tx.Clauses(lockingClause()).First(&app, appID).Error; err != nil {
			return err
		}
		if app.OwnerID != userID || app.Status != "pending" {
			return gorm.ErrInvalidData
		}
		var post models.Post
		if err := tx.Select("id", "is_featured", "status").First(&post, app.PostID).Error; err != nil {
			return err
		}
		if !post.IsFeatured || post.Status == models.PostStatusDeleted {
			return gorm.ErrInvalidData
		}
		return tx.Model(&app).Updates(map[string]interface{}{
			"status": status, "owner_reply": strings.TrimSpace(input.Reply), "reviewed_at": &now,
		}).Error
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "共同创作申请不可处理"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已处理共同创作申请"})
}

func (h *PostHandler) CreateRevisionProposal(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	postID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input revisionProposalInput
	_ = c.ShouldBind(&input)
	input.Title = strings.TrimSpace(input.Title)
	input.Content = strings.TrimSpace(input.Content)
	if input.Content == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "修改内容不能为空"})
		return
	}
	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil || post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if !post.IsFeatured {
		c.JSON(http.StatusBadRequest, gin.H{"error": "帖子已取消精华，不能提交修改版本"})
		return
	}
	var app models.CollaborationApplication
	if err := h.db.Where("post_id = ? AND applicant_id = ? AND status = ?", postID, userID, "approved").
		Order("reviewed_at DESC").First(&app).Error; err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": "共同创作申请通过后才能提交修改版本"})
		return
	}
	proposal := models.PostRevisionProposal{
		PostID: post.ID, CollaborationApplicationID: app.ID, ProposerID: userID, OwnerID: post.AuthorID,
		BaseTitle: post.Title, BaseContent: post.Content, BasePostUpdatedAt: post.UpdatedAt,
		ProposedTitle: input.Title, ProposedContent: input.Content,
		ChangeSummary: strings.TrimSpace(input.ChangeSummary), Status: "pending",
	}
	if proposal.ProposedTitle == "" {
		proposal.ProposedTitle = post.Title
	}
	if err := h.db.Create(&proposal).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交修改版本失败"})
		return
	}
	c.JSON(http.StatusCreated, proposal)
}

func (h *PostHandler) GetMyRevisionProposalsSent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var items []models.PostRevisionProposal
	if err := h.db.Where("proposer_id = ?", userID).
		Preload("Post").Preload("Owner").Order("created_at DESC").Find(&items).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取修改版本失败"})
		return
	}
	c.JSON(http.StatusOK, items)
}

func (h *PostHandler) GetMyRevisionProposalsReceived(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var items []models.PostRevisionProposal
	if err := h.db.Where("owner_id = ?", userID).
		Preload("Post").Preload("Proposer").Order("created_at DESC").Find(&items).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取待审核修改版本失败"})
		return
	}
	c.JSON(http.StatusOK, items)
}

func (h *PostHandler) ApproveRevisionProposal(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	proposalID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input ownerReviewInput
	_ = c.ShouldBind(&input)
	now := time.Now()
	var conflict bool
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var proposal models.PostRevisionProposal
		if err := tx.Clauses(lockingClause()).First(&proposal, proposalID).Error; err != nil {
			return err
		}
		if proposal.OwnerID != userID || proposal.Status != "pending" {
			return gorm.ErrInvalidData
		}
		result := tx.Model(&models.Post{}).
			Where("id = ? AND is_featured = ? AND status != ? AND updated_at = ?",
				proposal.PostID, true, models.PostStatusDeleted, proposal.BasePostUpdatedAt).
			Updates(map[string]interface{}{
				"title": proposal.ProposedTitle, "content": proposal.ProposedContent, "updated_at": now,
			})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 0 {
			conflict = true
			return gorm.ErrInvalidData
		}
		return tx.Model(&proposal).Updates(map[string]interface{}{
			"status": "published", "owner_reply": strings.TrimSpace(input.Reply),
			"reviewed_at": &now, "published_at": &now,
		}).Error
	}); err != nil {
		if conflict {
			c.JSON(http.StatusConflict, gin.H{"error": "原帖已被修改，请重新提交修改版本"})
			return
		}
		c.JSON(http.StatusBadRequest, gin.H{"error": "修改版本不可发布"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "修改版本已发布"})
}

func (h *PostHandler) RejectRevisionProposal(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	proposalID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input ownerReviewInput
	_ = c.ShouldBind(&input)
	now := time.Now()
	result := h.db.Model(&models.PostRevisionProposal{}).
		Where("id = ? AND owner_id = ? AND status = ?", proposalID, userID, "pending").
		Updates(map[string]interface{}{
			"status": "rejected", "owner_reply": strings.TrimSpace(input.Reply), "reviewed_at": &now,
		})
	if result.Error != nil || result.RowsAffected == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "修改版本不可驳回"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已驳回修改版本"})
}
