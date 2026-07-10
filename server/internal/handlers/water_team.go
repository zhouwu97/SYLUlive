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
	"shenliyuan/internal/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type WaterTeamHandler struct {
	db *gorm.DB
}

func NewWaterTeamHandler(db *gorm.DB) *WaterTeamHandler {
	return &WaterTeamHandler{db: db}
}

// currentUserOr401 获取当前登录用户
func (h *WaterTeamHandler) currentUserOr401(c *gin.Context) (uint, bool) {
	val, exists := c.Get("user_id")
	if !exists {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "请先登录"})
		return 0, false
	}
	userID, ok := val.(uint)
	if !ok || userID == 0 {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的用户身份"})
		return 0, false
	}
	return userID, true
}


type UpdateTeamRecruitmentStatusRequest struct {
	Status string `json:"status" binding:"required"`
}
type ApplyTeamRecruitmentRequest struct {
	Message      string `json:"message"`
	Availability string `json:"availability"`
}

// Apply POST /api/water/team/recruitments/:id/apply
func (h *WaterTeamHandler) Apply(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	recruitmentID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var req ApplyTeamRecruitmentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}
	req.Message = strings.TrimSpace(req.Message)
	req.Availability = strings.TrimSpace(req.Availability)

	if len([]rune(req.Message)) < 5 || len([]rune(req.Message)) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "申请留言请控制在5~500字"})
		return
	}

	var responseApp models.WaterTeamApplication
	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Preload("Post").First(&recruitment, recruitmentID).Error; err != nil {
			return fmt.Errorf("recruitment_not_found")
		}

		if recruitment.Post.AuthorID == userID {
			return fmt.Errorf("cannot_apply_own")
		}

		if recruitment.Post.Status == models.PostStatusDeleted {
			return fmt.Errorf("post_deleted")
		}

		if recruitment.Post.WaterTagID == nil {
			return fmt.Errorf("invalid_tag")
		}

		var tag models.WaterSectionTag
		if err := tx.First(&tag, *recruitment.Post.WaterTagID).Error; err != nil {
			return fmt.Errorf("invalid_tag")
		}

		if !tag.IsEnabled || tag.ContentMode != models.WaterTagModeTeamRecruitment {
			return fmt.Errorf("tag_disabled")
		}

		var section models.WaterSection
		if err := tx.First(&section, tag.SectionID).Error; err != nil {
			return fmt.Errorf("invalid_section")
		}

		if section.Status != "active" {
			return fmt.Errorf("section_inactive")
		}

		// Check if user is muted
		permSvc := services.NewWaterPermissionService(tx)
		if permSvc.IsMuted(section.ID, userID) {
			return fmt.Errorf("user_muted")
		}

		now := time.Now()
		effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
		if effectiveStatus != models.RecruitmentStatusRecruiting {
			return fmt.Errorf("recruitment_not_available")
		}

		var existing models.WaterTeamApplication
		err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("recruitment_id = ? AND applicant_id = ?", recruitment.ID, userID).First(&existing).Error
		if err == nil {
			if existing.Status == models.ApplicationStatusPending {
				return fmt.Errorf("already_applied")
			}
			if existing.Status == models.ApplicationStatusAccepted {
				return fmt.Errorf("already_joined")
			}
			// Re-apply if rejected/cancelled
			if err := tx.Model(&existing).Updates(map[string]interface{}{
				"status":       models.ApplicationStatusPending,
				"message":      req.Message,
				"availability": req.Availability,
				"reviewed_at":  nil,
				"owner_reply":  "",
			}).Error; err != nil {
				return err
			}
			
			if err := tx.First(&existing, existing.ID).Error; err != nil {
				return err
			}
			
			responseApp = existing
			return nil
		}

		app := models.WaterTeamApplication{
			RecruitmentID: recruitment.ID,
			PostID:        recruitment.PostID,
			ApplicantID:   userID,
			OwnerID:       recruitment.Post.AuthorID,
			Message:       req.Message,
			Availability:  req.Availability,
			Status:        models.ApplicationStatusPending,
		}

		if err := tx.Create(&app).Error; err != nil {
			return err
		}
		responseApp = app
		return nil
	})

	if err != nil {
		switch err.Error() {
		case "recruitment_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		case "cannot_apply_own":
			c.JSON(http.StatusBadRequest, gin.H{"error": "不能申请自己的招募"})
		case "post_deleted":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该帖子已被删除或屏蔽"})
		case "invalid_tag", "tag_disabled":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该标签不支持组队招募或已停用"})
		case "invalid_section", "section_inactive":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该版块已归档或不存在"})
		case "user_muted":
			c.JSON(http.StatusForbidden, gin.H{"error": "你已被该版块禁言，无法申请"})
		case "recruitment_not_available":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该招募目前不接受申请"})
		case "already_applied":
			c.JSON(http.StatusConflict, gin.H{"error": "您已经申请过该招募"})
		case "already_joined":
			c.JSON(http.StatusConflict, gin.H{"error": "您已加入该招募"})
		default:
			if utils.IsPostgresUniqueViolation(err) {
				c.JSON(http.StatusConflict, gin.H{"error": "您已经申请过该招募"})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"error": "提交申请失败"})
		}
		return
	}

	c.JSON(http.StatusCreated, responseApp)
}

type ReviewTeamApplicationRequest struct {
	Reply string `json:"reply"`
}

// Accept POST /api/water/team/applications/:id/accept
func (h *WaterTeamHandler) Accept(c *gin.Context) {
	h.reviewApplication(c, models.ApplicationStatusAccepted)
}

// Reject POST /api/water/team/applications/:id/reject
func (h *WaterTeamHandler) Reject(c *gin.Context) {
	h.reviewApplication(c, models.ApplicationStatusRejected)
}

func (h *WaterTeamHandler) reviewApplication(c *gin.Context, newStatus string) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	appID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申请ID"})
		return
	}

	var req ReviewTeamApplicationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}
	req.Reply = strings.TrimSpace(req.Reply)

	var initialApp models.WaterTeamApplication
	if err := h.db.First(&initialApp, appID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请失败"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, initialApp.RecruitmentID).Error; err != nil {
			return err
		}

		var app models.WaterTeamApplication
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}

		if app.RecruitmentID != recruitment.ID {
			return fmt.Errorf("invalid_assoc")
		}

		if app.OwnerID != userID {
			return fmt.Errorf("unauthorized")
		}

		if app.Status != models.ApplicationStatusPending {
			return fmt.Errorf("invalid_status")
		}

		if newStatus == models.ApplicationStatusAccepted {
			now := time.Now()
			effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
			if effectiveStatus != models.RecruitmentStatusRecruiting {
				return fmt.Errorf("recruitment_not_available")
			}
		}

		now := time.Now()
		if err := tx.Model(&app).Updates(map[string]interface{}{
			"status":      newStatus,
			"reviewed_at": now,
			"owner_reply": req.Reply,
		}).Error; err != nil {
			return err
		}

		if newStatus == models.ApplicationStatusAccepted {
			var acceptedCount int64
			if err := tx.Model(&models.WaterTeamApplication{}).
				Where("recruitment_id = ? AND status = ?", recruitment.ID, models.ApplicationStatusAccepted).
				Count(&acceptedCount).Error; err != nil {
				return err
			}

			if acceptedCount > int64(recruitment.NeededCount) {
				return fmt.Errorf("recruitment_not_available")
			}

			status := models.RecruitmentStatusRecruiting
			if acceptedCount >= int64(recruitment.NeededCount) {
				status = models.RecruitmentStatusFull
			}

			return tx.Model(&recruitment).Updates(map[string]interface{}{
				"accepted_count": acceptedCount,
				"status":         status,
			}).Error
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "app_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "invalid_status":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该申请已被处理"})
		case "recruitment_not_available":
			c.JSON(http.StatusBadRequest, gin.H{"error": "名额已满或招募已结束"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "处理失败"})
		}
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "处理成功"})
}

// Cancel POST /api/water/team/applications/:id/cancel
func (h *WaterTeamHandler) Cancel(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	appID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的申请ID"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var app models.WaterTeamApplication
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}

		if app.ApplicantID != userID {
			return fmt.Errorf("unauthorized")
		}

		if app.Status != models.ApplicationStatusPending {
			return fmt.Errorf("invalid_status")
		}

		app.Status = models.ApplicationStatusCancelled
		if err := tx.Save(&app).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "app_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "申请不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "invalid_status":
			c.JSON(http.StatusBadRequest, gin.H{"error": "状态无效"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "取消失败"})
		}
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "已取消"})
}

// GetMyApplications GET /api/water/team/my_applications
func (h *WaterTeamHandler) GetMyApplications(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	var apps []models.WaterTeamApplication
	if err := h.db.Preload("Recruitment").Preload("Post").Preload("Post.Author").Where("applicant_id = ?", userID).Order("created_at desc").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请列表失败"})
		return
	}

	c.JSON(http.StatusOK, apps)
}

// GetRecruitmentApplications GET /api/water/team/recruitments/:id/applications
func (h *WaterTeamHandler) GetRecruitmentApplications(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	recruitmentID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var recruitment models.WaterTeamRecruitment
	if err := h.db.Preload("Post").First(&recruitment, recruitmentID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		return
	}

	if recruitment.Post.AuthorID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		return
	}

	var apps []models.WaterTeamApplication
	if err := h.db.Preload("Applicant").Where("recruitment_id = ?", recruitmentID).Order("created_at desc").Find(&apps).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取申请列表失败"})
		return
	}

	c.JSON(http.StatusOK, apps)
}

// UpdateRecruitmentStatus PATCH /api/water/team/recruitments/:id/status
func (h *WaterTeamHandler) UpdateRecruitmentStatus(c *gin.Context) {
	userID, ok := h.currentUserOr401(c)
	if !ok {
		return
	}

	idStr := c.Param("id")
	recruitmentID, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募ID"})
		return
	}

	var req UpdateTeamRecruitmentStatusRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	if req.Status != string(models.RecruitmentStatusClosed) && req.Status != string(models.RecruitmentStatusRecruiting) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的招募状态"})
		return
	}

	var responsePost models.Post
	var initialRecruitment models.WaterTeamRecruitment
	if err := h.db.First(&initialRecruitment, recruitmentID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "未找到该招募信息"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取招募信息失败"})
		return
	}

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var post models.Post
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&post, initialRecruitment.PostID).Error; err != nil {
			return fmt.Errorf("post_not_found")
		}

		var recruitment models.WaterTeamRecruitment
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, recruitmentID).Error; err != nil {
			return fmt.Errorf("recruitment_not_found")
		}
		
		if recruitment.PostID != post.ID {
			return fmt.Errorf("mismatch")
		}

		if post.AuthorID != userID {
			return fmt.Errorf("unauthorized")
		}

		if post.Status == models.PostStatusDeleted {
			return fmt.Errorf("post_deleted")
		}

		if req.Status == string(models.RecruitmentStatusClosed) {
			if recruitment.Status != models.RecruitmentStatusRecruiting && recruitment.Status != models.RecruitmentStatusFull {
				return fmt.Errorf("cannot_close")
			}
			recruitment.Status = models.RecruitmentStatusClosed
		} else if req.Status == string(models.RecruitmentStatusRecruiting) {
			if recruitment.Status != models.RecruitmentStatusClosed {
				return fmt.Errorf("cannot_reopen")
			}

			if post.WaterTagID == nil {
				return fmt.Errorf("invalid_tag")
			}

			var tag models.WaterSectionTag
			if err := tx.First(&tag, *post.WaterTagID).Error; err != nil {
				return fmt.Errorf("invalid_tag")
			}

			if !tag.IsEnabled || tag.ContentMode != models.WaterTagModeTeamRecruitment {
				return fmt.Errorf("tag_disabled")
			}

			var section models.WaterSection
			if err := tx.First(&section, tag.SectionID).Error; err != nil {
				return fmt.Errorf("invalid_section")
			}

			if section.Status != "active" {
				return fmt.Errorf("section_inactive")
			}

			if recruitment.Deadline != nil && recruitment.Deadline.Before(time.Now()) {
				return fmt.Errorf("deadline_passed")
			}

			var acceptedCount int64
			if err := tx.Model(&models.WaterTeamApplication{}).Where("recruitment_id = ? AND status = ?", recruitment.ID, models.ApplicationStatusAccepted).Count(&acceptedCount).Error; err != nil {
				return err
			}

			recruitment.AcceptedCount = int(acceptedCount)
			if recruitment.AcceptedCount >= recruitment.NeededCount {
				return fmt.Errorf("already_full")
			}

			recruitment.Status = models.RecruitmentStatusRecruiting
		}

		if err := tx.Save(&recruitment).Error; err != nil {
			return err
		}

		if err := tx.Preload("Author").Preload("Images").Preload("Images.File").First(&responsePost, post.ID).Error; err != nil {
			return err
		}

		return nil
	})

	if err != nil {
		switch err.Error() {
		case "recruitment_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		case "post_not_found":
			c.JSON(http.StatusNotFound, gin.H{"error": "帖子不存在"})
		case "unauthorized":
			c.JSON(http.StatusForbidden, gin.H{"error": "无权限"})
		case "post_deleted":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该帖子已被删除或屏蔽"})
		case "cannot_close":
			c.JSON(http.StatusBadRequest, gin.H{"error": "当前状态无法关闭"})
		case "cannot_reopen":
			c.JSON(http.StatusBadRequest, gin.H{"error": "当前状态无法重新开启"})
		case "invalid_tag", "tag_disabled":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该标签不支持组队招募或已停用"})
		case "invalid_section", "section_inactive":
			c.JSON(http.StatusBadRequest, gin.H{"error": "该版块已归档或不存在"})
		case "deadline_passed":
			c.JSON(http.StatusBadRequest, gin.H{"error": "截止时间已过，请先修改截止时间"})
		case "already_full":
			c.JSON(http.StatusBadRequest, gin.H{"error": "名额已满，无法重新开启"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "处理失败"})
		}
		return
	}

	postHandler := &PostHandler{db: h.db}
	responsePosts := []models.Post{responsePost}
	postHandler.hydratePosts(c, responsePosts, time.Now())

	c.JSON(http.StatusOK, gin.H{"post": responsePosts[0]})
}
