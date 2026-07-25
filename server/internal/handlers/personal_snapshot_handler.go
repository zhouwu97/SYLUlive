package handlers

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// PersonalSnapshotHandler 提供用户主动授权的结构化二课快照接口。
// 所有路由必须在 JWT 鉴权后注册，服务端不会接受二课凭据或原始页面内容。
type PersonalSnapshotHandler struct {
	service     *services.PersonalSnapshotService
	permissions *services.AIUserPermissionService
}

func NewPersonalSnapshotHandler(service *services.PersonalSnapshotService) *PersonalSnapshotHandler {
	return &PersonalSnapshotHandler{service: service}
}

// SetAIUserPermissionService 允许应用装配层将“永不上传二课快照”策略接入已有上传接口。
func (handler *PersonalSnapshotHandler) SetAIUserPermissionService(service *services.AIUserPermissionService) {
	handler.permissions = service
}

func (handler *PersonalSnapshotHandler) PutErke(c *gin.Context) {
	if handler.permissions != nil {
		policy, err := handler.permissions.Policy(c.Request.Context(), c.GetUint("user_id"), models.AIUserPermissionErkeSnapshotUpload)
		if err != nil {
			writeAIUserPermissionError(c, err)
			return
		}
		if policy == models.AIUserPermissionNever {
			c.JSON(http.StatusForbidden, gin.H{"code": "erke_snapshot_upload_disabled", "message": "你已在隐私设置中关闭二课快照上传"})
			return
		}
	}
	var request services.ErkeSnapshotUpload
	if err := decodeStrictJSON(c, &request, 520<<10); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_erke_snapshot", "message": "二课快照格式无效"})
		return
	}
	result, err := handler.service.StoreErke(c.Request.Context(), c.GetUint("user_id"), request)
	if err != nil {
		writePersonalSnapshotError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"snapshot": result})
}

func (handler *PersonalSnapshotHandler) GetErke(c *gin.Context) {
	lookup, err := handler.service.LookupErke(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writePersonalSnapshotError(c, err)
		return
	}
	if !lookup.Found {
		c.JSON(http.StatusNotFound, gin.H{"code": "personal_snapshot_not_found", "message": "尚未上传二课快照"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"snapshot": lookup.Result})
}

func (handler *PersonalSnapshotHandler) DeleteErke(c *gin.Context) {
	if err := handler.service.DeleteErke(c.Request.Context(), c.GetUint("user_id")); err != nil {
		writePersonalSnapshotError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

func writePersonalSnapshotError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, services.ErrPersonalSnapshotNotFound):
		c.JSON(http.StatusNotFound, gin.H{"code": "personal_snapshot_not_found", "message": "个人快照不存在"})
	case errors.Is(err, services.ErrInvalidPersonalSnapshot):
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_erke_snapshot", "message": "二课快照格式无效或包含不允许的数据"})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"code": "personal_snapshot_unavailable", "message": "个人快照服务暂时不可用"})
	}
}
