package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// AIUserPermissionHandler 提供校园 Agent 个人数据权限的查看和更新接口。
// 路由只接受当前 JWT 用户，禁止客户端传入 user_id。
type AIUserPermissionHandler struct {
	service *services.AIUserPermissionService
}

func NewAIUserPermissionHandler(service *services.AIUserPermissionService) *AIUserPermissionHandler {
	return &AIUserPermissionHandler{service: service}
}

func (handler *AIUserPermissionHandler) List(c *gin.Context) {
	permissions, err := handler.service.List(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"permissions": permissions})
}

type updateAIUserPermissionRequest struct {
	Scope  models.AIUserPermissionScope  `json:"scope"`
	Policy models.AIUserPermissionPolicy `json:"policy"`
}

func (handler *AIUserPermissionHandler) Update(c *gin.Context) {
	var request updateAIUserPermissionRequest
	if err := decodeStrictJSON(c, &request, 4<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_ai_personal_data_permission", "message": "个人数据权限参数无效"})
		return
	}
	permission, err := handler.service.Set(c.Request.Context(), c.GetUint("user_id"), request.Scope, request.Policy)
	if err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"permission": permission})
}

type setAIUserPermissionModeRequest struct {
	Mode string `json:"mode"`
}

func (handler *AIUserPermissionHandler) GetMode(c *gin.Context) {
	mode, err := handler.service.Mode(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"mode": mode})
}

func (handler *AIUserPermissionHandler) SetMode(c *gin.Context) {
	var request setAIUserPermissionModeRequest
	if err := decodeStrictJSON(c, &request, 1<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_ai_personal_data_permission", "message": "Agent 权限模式无效"})
		return
	}
	if err := handler.service.SetMode(c.Request.Context(), c.GetUint("user_id"), request.Mode); err != nil {
		writeAIUserPermissionError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"mode": request.Mode})
}

func writeAIUserPermissionError(c *gin.Context, err error) {
	if errors.Is(err, services.ErrInvalidAIUserPermission) {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_ai_personal_data_permission", "message": "个人数据权限参数无效"})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"code": "ai_personal_data_permission_unavailable", "message": "个人数据权限服务暂时不可用"})
}
