package handlers

import (
	"errors"
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/services"
)

type PollHandler struct {
	db      *gorm.DB
	service *services.PollService
}

func NewPollHandler(db *gorm.DB) *PollHandler {
	return &PollHandler{db: db, service: services.NewPollService(db)}
}

func (h *PollHandler) List(c *gin.Context) {
	result, err := h.service.List(services.PollListInput{
		Sort: c.DefaultQuery("sort", "recommend"), Category: c.DefaultQuery("category", "all"),
		Page: queryInt(c, "page", 1), Limit: queryInt(c, "limit", 20),
	}, contextUserID(c))
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *PollHandler) ListMine(c *gin.Context) {
	scope := c.DefaultQuery("scope", "created")
	if scope != "created" && scope != "voted" {
		c.JSON(http.StatusBadRequest, gin.H{"code": services.PollCodeInvalidInput, "error": "scope 仅支持 created 或 voted"})
		return
	}
	userID := contextUserID(c)
	result, err := h.service.List(services.PollListInput{
		Sort: c.DefaultQuery("sort", "latest"), Category: c.DefaultQuery("category", "all"),
		Page: queryInt(c, "page", 1), Limit: queryInt(c, "limit", 20), Scope: scope, UserID: userID,
	}, userID)
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *PollHandler) Get(c *gin.Context) {
	id, ok := pollParamID(c)
	if !ok {
		return
	}
	post, err := h.service.Get(id, contextUserID(c))
	if err != nil {
		h.writeError(c, err)
		return
	}
	if err := h.db.Model(&post).UpdateColumn("view_count", gorm.Expr("view_count + 1")).Error; err == nil {
		post.ViewCount++
	}
	c.JSON(http.StatusOK, post)
}

func (h *PollHandler) Create(c *gin.Context) {
	var input services.CreatePollInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": services.PollCodeInvalidInput, "error": "请求格式错误"})
		return
	}
	post, err := h.service.Create(contextUserID(c), contextRole(c), input)
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, post)
}

func (h *PollHandler) Update(c *gin.Context) {
	id, ok := pollParamID(c)
	if !ok {
		return
	}
	var input services.CreatePollInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": services.PollCodeInvalidInput, "error": "请求格式错误"})
		return
	}
	post, err := h.service.Update(id, contextUserID(c), contextRole(c), input)
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, post)
}

func (h *PollHandler) PutBallot(c *gin.Context) {
	id, ok := pollParamID(c)
	if !ok {
		return
	}
	var input struct {
		OptionIDs []uint `json:"option_ids"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": services.PollCodeInvalidInput, "error": "请求格式错误"})
		return
	}
	post, err := h.service.PutBallot(id, contextUserID(c), input.OptionIDs)
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, post)
}

func (h *PollHandler) Close(c *gin.Context) {
	id, ok := pollParamID(c)
	if !ok {
		return
	}
	post, err := h.service.Close(id, contextUserID(c), contextRole(c))
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, post)
}

func (h *PollHandler) Delete(c *gin.Context) {
	id, ok := pollParamID(c)
	if !ok {
		return
	}
	if err := h.service.Delete(id, contextUserID(c), contextRole(c)); err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "投票已删除"})
}

func (h *PollHandler) writeError(c *gin.Context, err error) {
	var pollErr *services.PollError
	if !errors.As(err, &pollErr) {
		log.Printf("[POLL] 请求失败: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"code": "poll_internal_error", "error": "投票服务暂时不可用"})
		return
	}
	status := http.StatusBadRequest
	switch pollErr.Code {
	case services.PollCodeNotFound, services.PollCodeDeleted:
		status = http.StatusNotFound
	case services.PollCodePermissionDenied:
		status = http.StatusForbidden
	case services.PollCodeCreationLimit:
		status = http.StatusTooManyRequests
	case services.PollCodeEnded, services.PollCodeRulesLocked, services.PollCodeChangeDisabled:
		status = http.StatusConflict
	}
	c.JSON(status, gin.H{"code": pollErr.Code, "error": pollErr.Message})
}

func pollParamID(c *gin.Context) (uint, bool) {
	value, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || value == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": services.PollCodeInvalidInput, "error": "投票 ID 无效"})
		return 0, false
	}
	return uint(value), true
}

func contextUserID(c *gin.Context) uint {
	value, exists := c.Get("user_id")
	if !exists {
		return 0
	}
	userID, _ := value.(uint)
	return userID
}

func contextRole(c *gin.Context) string {
	value, _ := c.Get("role")
	role, _ := value.(string)
	return role
}

func queryInt(c *gin.Context, key string, fallback int) int {
	value, err := strconv.Atoi(c.Query(key))
	if err != nil {
		return fallback
	}
	return value
}
