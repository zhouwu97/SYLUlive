package handlers

import (
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

type applicationReasonInput struct {
	Reason string `json:"reason" form:"reason"`
}

type reviewInput struct {
	Reason        string `json:"reason" form:"reason"`
	IsMalicious   bool   `json:"is_malicious" form:"is_malicious"`
	PenaltyPoints int    `json:"penalty_points" form:"penalty_points"`
}

func parseUintParam(c *gin.Context, name string) (uint, bool) {
	id, err := strconv.ParseUint(c.Param(name), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的ID"})
		return 0, false
	}
	return uint(id), true
}

func currentUserID(c *gin.Context) (uint, bool) {
	raw, ok := c.Get("user_id")
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return 0, false
	}
	id, ok := raw.(uint)
	if !ok || id == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "登录状态无效"})
		return 0, false
	}
	return id, true
}

func lockingClause() clause.Locking {
	return clause.Locking{Strength: "UPDATE"}
}

func (h *PostHandler) GetFeaturedList(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	if page < 1 {
		page = 1
	}
	if limit < 1 || limit > 50 {
		limit = 20
	}
	offset := (page - 1) * limit

	query := h.db.Model(&models.Post{}).
		Where("status != ? AND is_featured = ?", models.PostStatusDeleted, true).
		Preload("Author").Preload("Images").Preload("Images.File")

	var total int64
	query.Count(&total)

	var posts []models.Post
	if err := query.Order("featured_at DESC NULLS LAST").Order("created_at DESC").
		Offset(offset).Limit(limit).Find(&posts).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取精华列表失败"})
		return
	}
	h.fillLikes(c, posts)
	if posts == nil {
		posts = []models.Post{}
	}
	c.JSON(http.StatusOK, gin.H{"posts": posts, "total": total, "page": page, "limit": limit})
}

func (h *PostHandler) CreateFeaturedApplication(c *gin.Context) {
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
		c.JSON(http.StatusBadRequest, gin.H{"error": "请填写申请理由"})
		return
	}

	var post models.Post
	if err := h.db.First(&post, postID).Error; err != nil || post.Status == models.PostStatusDeleted {
		c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		return
	}
	if post.IsFeatured {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该帖子已经是精华"})
		return
	}

	app := models.FeaturedApplication{
		PostID: post.ID, ApplicantID: userID, Reason: input.Reason, Status: "pending",
	}
	if err := h.db.Create(&app).Error; err != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "该帖子已有待审核精华申请"})
		return
	}
	c.JSON(http.StatusCreated, app)
}

func (h *PostHandler) GetMyFeaturedApplications(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var apps []models.FeaturedApplication
	if err := h.db.Where("applicant_id = ?", userID).
		Preload("Post").Preload("Reviewer").
		Order("created_at DESC").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请列表失败"})
		return
	}
	c.JSON(http.StatusOK, apps)
}

func (h *PostHandler) AdminGetFeaturedApplications(c *gin.Context) {
	status := strings.TrimSpace(c.DefaultQuery("status", "pending"))
	query := h.db.Model(&models.FeaturedApplication{}).
		Preload("Post").Preload("Applicant").Preload("Reviewer")
	if status != "" && status != "all" {
		query = query.Where("status = ?", status)
	}
	var apps []models.FeaturedApplication
	if err := query.Order("created_at DESC").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取精华申请失败"})
		return
	}
	c.JSON(http.StatusOK, apps)
}

func (h *PostHandler) AdminApproveFeaturedApplication(c *gin.Context) {
	reviewerID, ok := currentUserID(c)
	if !ok {
		return
	}
	appID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input reviewInput
	_ = c.ShouldBind(&input)
	now := time.Now()

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var app models.FeaturedApplication
		if err := tx.Clauses(lockingClause()).First(&app, appID).Error; err != nil {
			return err
		}
		if app.Status != "pending" {
			return gorm.ErrInvalidData
		}
		var post models.Post
		if err := tx.Clauses(lockingClause()).First(&post, app.PostID).Error; err != nil {
			return err
		}
		if post.Status == models.PostStatusDeleted || post.IsFeatured {
			return gorm.ErrInvalidData
		}
		if err := tx.Model(&app).Updates(map[string]interface{}{
			"status": "approved", "reviewer_id": reviewerID,
			"review_reason": strings.TrimSpace(input.Reason), "reviewed_at": &now,
		}).Error; err != nil {
			return err
		}
		return tx.Model(&post).Updates(map[string]interface{}{
			"is_featured": true, "featured_at": &now, "featured_by": reviewerID,
			"featured_reason": strings.TrimSpace(input.Reason),
		}).Error
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "精华申请不可通过或已被处理"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已通过精华申请"})
}

func (h *PostHandler) AdminRejectFeaturedApplication(c *gin.Context) {
	reviewerID, ok := currentUserID(c)
	if !ok {
		return
	}
	appID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input reviewInput
	_ = c.ShouldBind(&input)
	if !input.IsMalicious {
		input.PenaltyPoints = 0
	} else if input.PenaltyPoints < 0 {
		input.PenaltyPoints = 0
	}
	now := time.Now()

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var app models.FeaturedApplication
		if err := tx.Clauses(lockingClause()).First(&app, appID).Error; err != nil {
			return err
		}
		if app.Status != "pending" {
			return gorm.ErrInvalidData
		}
		if err := tx.Model(&app).Updates(map[string]interface{}{
			"status": "rejected", "reviewer_id": reviewerID,
			"review_reason": strings.TrimSpace(input.Reason), "is_malicious": input.IsMalicious,
			"penalty_points": input.PenaltyPoints, "reviewed_at": &now,
		}).Error; err != nil {
			return err
		}
		if input.IsMalicious && input.PenaltyPoints > 0 {
			if err := tx.Model(&models.User{}).Where("id = ?", app.ApplicantID).
				UpdateColumn("credit_score", gorm.Expr("GREATEST(credit_score - ?, 0)", input.PenaltyPoints)).Error; err != nil {
				return err
			}
			return tx.Create(&models.ReputationLog{
				UserID: app.ApplicantID, OperatorID: reviewerID, Action: "featured_application_reject",
				Delta: -input.PenaltyPoints, Reason: strings.TrimSpace(input.Reason),
				RefType: "featured_application", RefID: app.ID,
			}).Error
		}
		return nil
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "精华申请不可驳回或已被处理"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已驳回精华申请"})
}

func (h *PostHandler) AdminUnfeaturePost(c *gin.Context) {
	postID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	if err := h.db.Model(&models.Post{}).Where("id = ?", postID).Updates(map[string]interface{}{
		"is_featured": false, "featured_at": nil, "featured_by": 0, "featured_reason": "",
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "取消精华失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已取消精华"})
}
