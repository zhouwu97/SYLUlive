package handlers

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func (h *EmojiPackSubmissionHandler) GetCreator(c *gin.Context) {
	var creator models.EmojiCreator
	err := h.service.DB.WithContext(c.Request.Context()).First(&creator, "user_id = ?", c.GetUint("user_id")).Error
	c.Header("Cache-Control", "private, no-store")
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(200, gin.H{"status": "none", "version": 0})
		return
	}
	if err != nil {
		emojiPackError(c, err)
		return
	}
	c.JSON(200, creator)
}

func (h *EmojiPackSubmissionHandler) ApplyCreator(c *gin.Context) {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 16*1024)
	var input struct {
		Description string `json:"description"`
		Rights      bool   `json:"rights_confirmed"`
		Version     int    `json:"version"`
	}
	if c.ShouldBindJSON(&input) != nil || !input.Rights {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	creator, err := h.service.ApplyCreator(c.Request.Context(), c.GetUint("user_id"), input.Description, input.Version)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(200, creator)
}

func (h *EmojiPackSubmissionHandler) ListCreators(c *gin.Context) {
	if !h.admin(c) {
		emojiPackError(c, services.ErrEmojiPackForbidden)
		return
	}
	status := c.DefaultQuery("status", models.EmojiCreatorPending)
	if status != models.EmojiCreatorPending && status != models.EmojiCreatorActive && status != models.EmojiCreatorRejected && status != models.EmojiCreatorSuspended {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	page, err := strconv.Atoi(c.DefaultQuery("page", "1"))
	if err != nil || page < 1 || page > 100000 {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	query := h.service.DB.WithContext(c.Request.Context()).Model(&models.EmojiCreator{}).Where("status = ?", status)
	var total int64
	if err := query.Count(&total).Error; err != nil {
		emojiPackError(c, err)
		return
	}
	items := []models.EmojiCreator{}
	if err := query.Order("updated_at DESC, user_id DESC").Offset((page - 1) * 20).Limit(20).Find(&items).Error; err != nil {
		emojiPackError(c, err)
		return
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(200, gin.H{"items": items, "total": total, "page": page, "limit": 20})
}

func (h *EmojiPackSubmissionHandler) ReviewCreator(c *gin.Context) {
	if !h.admin(c) {
		emojiPackError(c, services.ErrEmojiPackForbidden)
		return
	}
	id, err := strconv.ParseUint(c.Param("userId"), 10, 32)
	if err != nil || id == 0 {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 4096)
	var input struct {
		Action  string `json:"action"`
		Reason  string `json:"reason"`
		Version int    `json:"version"`
	}
	if c.ShouldBindJSON(&input) != nil {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	if err := h.service.ReviewCreator(c.Request.Context(), uint(id), c.GetUint("user_id"), input.Version, input.Action, input.Reason); err != nil {
		emojiPackError(c, err)
		return
	}
	c.JSON(200, gin.H{"message": "处理成功"})
}
