package handlers

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"

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

	var recruitment models.WaterTeamRecruitment
	if err := h.db.Preload("Post").First(&recruitment, recruitmentID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "招募信息不存在"})
		return
	}

	if recruitment.Post.AuthorID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不能申请自己的招募"})
		return
	}

	now := time.Now()
	effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
	if effectiveStatus != models.RecruitmentStatusRecruiting {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该招募目前不接受申请"})
		return
	}

	// 检查是否已有申请
	var existing models.WaterTeamApplication
	err = h.db.Where("recruitment_id = ? AND applicant_id = ?", recruitmentID, userID).First(&existing).Error
	if err == nil {
		if existing.Status == models.ApplicationStatusPending || existing.Status == models.ApplicationStatusAccepted {
			c.JSON(http.StatusConflict, gin.H{"error": "您已经申请过该招募"})
			return
		}
		// 如果被拒绝或已取消，可以重新申请
		existing.Status = models.ApplicationStatusPending
		existing.Message = req.Message
		existing.Availability = req.Availability
		existing.ReviewedAt = nil
		existing.OwnerReply = ""
		if err := h.db.Save(&existing).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "重新提交申请失败"})
			return
		}
		c.JSON(http.StatusOK, existing)
		return
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

	if err := h.db.Create(&app).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交申请失败"})
		return
	}

	c.JSON(http.StatusCreated, app)
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

	err = h.db.Transaction(func(tx *gorm.DB) error {
		var app models.WaterTeamApplication
		if err := tx.First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}

		if app.OwnerID != userID {
			return fmt.Errorf("unauthorized")
		}

		if app.Status != models.ApplicationStatusPending {
			return fmt.Errorf("invalid_status")
		}

		var recruitment models.WaterTeamRecruitment
		// 加锁，防止超募
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, app.RecruitmentID).Error; err != nil {
			return err
		}

		if newStatus == models.ApplicationStatusAccepted {
			now := time.Now()
			effectiveStatus := models.EffectiveRecruitmentStatus(recruitment, now)
			if effectiveStatus != models.RecruitmentStatusRecruiting {
				return fmt.Errorf("recruitment_not_available")
			}

			recruitment.AcceptedCount++
			if recruitment.AcceptedCount >= recruitment.NeededCount && recruitment.Status == models.RecruitmentStatusRecruiting {
				recruitment.Status = models.RecruitmentStatusFull
			}
			if err := tx.Save(&recruitment).Error; err != nil {
				return err
			}
		}

		now := time.Now()
		app.Status = newStatus
		app.ReviewedAt = &now
		app.OwnerReply = req.Reply
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
		if err := tx.First(&app, appID).Error; err != nil {
			return fmt.Errorf("app_not_found")
		}

		if app.ApplicantID != userID {
			return fmt.Errorf("unauthorized")
		}

		if app.Status != models.ApplicationStatusPending && app.Status != models.ApplicationStatusAccepted {
			return fmt.Errorf("invalid_status")
		}

		if app.Status == models.ApplicationStatusAccepted {
			var recruitment models.WaterTeamRecruitment
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&recruitment, app.RecruitmentID).Error; err != nil {
				return err
			}
			recruitment.AcceptedCount--
			if recruitment.AcceptedCount < 0 {
				recruitment.AcceptedCount = 0
			}
			if recruitment.AcceptedCount < recruitment.NeededCount && recruitment.Status == models.RecruitmentStatusFull {
				recruitment.Status = models.RecruitmentStatusRecruiting
			}
			if err := tx.Save(&recruitment).Error; err != nil {
				return err
			}
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
