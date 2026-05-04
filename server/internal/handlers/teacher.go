package handlers

import (
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

type TeacherHandler struct {
	db *gorm.DB
}

func NewTeacherHandler(db *gorm.DB) *TeacherHandler {
	return &TeacherHandler{db: db}
}

// GetList 获取教师列表（按差评数降序 = 排行榜）
func (h *TeacherHandler) GetList(c *gin.Context) {
	var teachers []models.Teacher
	h.db.Where("verified = ?", true).Order("negative_count DESC, positive_count ASC").Find(&teachers)
	c.JSON(http.StatusOK, teachers)
}

// Create 添加教师（需管理员验证）
func (h *TeacherHandler) Create(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")

	var input struct {
		Name       string `json:"name" binding:"required"`
		Department string `json:"department"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 查重
	var exist models.Teacher
	if h.db.Where("name = ?", input.Name).First(&exist).Error == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "该教师已存在"})
		return
	}

	teacher := models.Teacher{
		Name:       input.Name,
		Department: input.Department,
		CreatedBy:  userID.(uint),
		Verified:   role == "admin" || role == "super_admin", // 管理员添加自动验证
	}

	if err := h.db.Create(&teacher).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "添加失败"})
		return
	}
	c.JSON(http.StatusCreated, teacher)
}

// Verify 管理员验证教师
func (h *TeacherHandler) Verify(c *gin.Context) {
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}
	h.db.Model(&models.Teacher{}).Where("id = ?", id).Update("verified", true)
	c.JSON(http.StatusOK, gin.H{"message": "已验证"})
}

// Rate 给教师评分
func (h *TeacherHandler) Rate(c *gin.Context) {
	userID, _ := c.Get("user_id")
	idStr := c.Param("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效ID"})
		return
	}

	var input struct {
		Rating  string `json:"rating" binding:"required"` // positive/negative
		Comment string `json:"comment"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 检查是否已评价
	var exist models.TeacherRating
	if h.db.Where("teacher_id = ? AND user_id = ?", id, userID).First(&exist).Error == nil {
		c.JSON(http.StatusConflict, gin.H{"error": "您已经评价过该教师"})
		return
	}

	rating := models.TeacherRating{
		TeacherID: uint(id),
		UserID:    userID.(uint),
		Rating:    input.Rating,
		Comment:   input.Comment,
	}
	if err := h.db.Create(&rating).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "评价失败"})
		return
	}

	// 更新计数
	if input.Rating == "positive" {
		h.db.Model(&models.Teacher{}).Where("id = ?", id).UpdateColumn("positive_count", gorm.Expr("positive_count + 1"))
	} else {
		h.db.Model(&models.Teacher{}).Where("id = ?", id).UpdateColumn("negative_count", gorm.Expr("negative_count + 1"))
	}

	c.JSON(http.StatusCreated, rating)
}

// GetViolations 获取用户违规记录
func (h *TeacherHandler) GetViolations(c *gin.Context) {
	userIDStr := c.Query("user_id")
	var violations []models.UserViolation
	query := h.db.Preload("User")
	if userIDStr != "" {
		query = query.Where("user_id = ?", userIDStr)
	}
	query.Order("created_at DESC").Find(&violations)
	c.JSON(http.StatusOK, violations)
}

// AddViolation 添加违规记录 + 禁言
func (h *TeacherHandler) AddViolation(c *gin.Context) {
	var input struct {
		UserID  uint   `json:"user_id" binding:"required"`
		BoardID uint   `json:"board_id" binding:"required"`
		Reason  string `json:"reason" binding:"required"`
		Action  string `json:"action" binding:"required"` // delete_post / delete_reply
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 统计历史违规次数
	var count int64
	h.db.Model(&models.UserViolation{}).Where("user_id = ? AND board_id = ?", input.UserID, input.BoardID).Count(&count)
	violationCount := int(count) + 1

	v := models.UserViolation{
		UserID:  input.UserID,
		BoardID: input.BoardID,
		Reason:  input.Reason,
		Action:  input.Action,
		Count:   violationCount,
	}

	// 禁言处罚
	switch {
	case violationCount >= 3:
		// 永久禁止该板块发言
		v.Count = violationCount
	case violationCount == 2:
		// 禁言1个月
		t := time.Now().AddDate(0, 1, 0)
		v.MutedUntil = &t
	case violationCount == 1:
		// 禁言1周
		t := time.Now().AddDate(0, 0, 7)
		v.MutedUntil = &t
	}

	if err := h.db.Create(&v).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录失败"})
		return
	}
	c.JSON(http.StatusCreated, v)
}

// AppealViolation 申诉违规
func (h *TeacherHandler) AppealViolation(c *gin.Context) {
	idStr := c.Param("id")
	id, _ := strconv.ParseUint(idStr, 10, 64)

	var v models.UserViolation
	if h.db.First(&v, id).Error != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "记录不存在"})
		return
	}

	// 标记已申诉，等管理员处理
	h.db.Model(&v).Update("appealed", true)
	c.JSON(http.StatusOK, gin.H{"message": "申诉已提交"})
}

// HandleAppeal 管理员处理申诉
func (h *TeacherHandler) HandleAppeal(c *gin.Context) {
	idStr := c.Param("id")
	id, _ := strconv.ParseUint(idStr, 10, 64)

	var input struct {
		Approved bool   `json:"approved"`
		Reason   string `json:"reason"`
	}
	c.ShouldBindJSON(&input)

	var v models.UserViolation
	if h.db.First(&v, id).Error != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "记录不存在"})
		return
	}

	if input.Approved {
		// 申诉成功，删除记录（减少违规次数）
		h.db.Delete(&v)
		c.JSON(http.StatusOK, gin.H{"message": "申诉成功，违规记录已删除"})
	} else {
		h.db.Model(&v).Update("appealed", false)
		c.JSON(http.StatusOK, gin.H{"message": "申诉被驳回"})
	}
}
