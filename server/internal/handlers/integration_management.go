package handlers

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func (h *IntegrationHandler) UploadGrades(c *gin.Context) {
	var input services.IntegrationGradesUpload
	if decodeStrictJSON(c, &input, 520<<10) != nil {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_personal_upload"})
		return
	}
	if err := h.auth.StoreUploadedGrades(c.Request.Context(), c.GetUint("user_id"), input); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"message": "已同步当前学期成绩，需另行授权助手才可在本人私聊查询。"})
}

func (h *IntegrationHandler) DeleteUploadedGrades(c *gin.Context) {
	if err := h.auth.DeleteUploadedGrades(c.Request.Context(), c.GetUint("user_id")); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *IntegrationHandler) Personal(dataset string) gin.HandlerFunc {
	return func(c *gin.Context) {
		for key := range c.Request.URL.Query() {
			if key != "offset" && key != "limit" {
				writeIntegrationError(c, &services.IntegrationError{Code: "invalid_request", Status: 422}, false)
				return
			}
		}
		offset, err := strconv.Atoi(c.DefaultQuery("offset", "0"))
		if err != nil {
			c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
			return
		}
		limit, err := strconv.Atoi(c.DefaultQuery("limit", "20"))
		if err != nil {
			c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
			return
		}
		binding := c.MustGet("integration_binding").(models.IntegrationBinding)
		result, err := h.auth.ReadPersonal(c.Request.Context(), binding, dataset, offset, limit)
		if err != nil {
			writeIntegrationError(c, err, false)
			return
		}
		c.JSON(http.StatusOK, gin.H{"data": result})
	}
}

func (h *IntegrationHandler) AdminBindings(c *gin.Context) {
	page, err := strconv.Atoi(c.DefaultQuery("page", "1"))
	if err != nil || page < 1 || page > 100000 {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
		return
	}
	state := c.Query("state")
	if state != "" && state != "active" && state != "revoked" {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
		return
	}
	query := h.db.WithContext(c.Request.Context()).Model(&models.IntegrationBinding{})
	if state != "" {
		query = query.Where("state = ?", state)
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	var bindings []models.IntegrationBinding
	if err := query.Order("created_at DESC, id DESC").Limit(30).Offset((page - 1) * 30).Find(&bindings).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	rows := make([]gin.H, 0, len(bindings))
	for _, binding := range bindings {
		var user struct{ Nickname string }
		if err := h.db.Model(&models.User{}).Select("nickname").Where("id = ?", binding.OwnerID).Take(&user).Error; err != nil {
			writeIntegrationError(c, err, false)
			return
		}
		rows = append(rows, gin.H{"binding_id": binding.ID, "nickname": user.Nickname, "installation_name": binding.InstallationName, "state": binding.State, "scopes": strings.Fields(binding.Scopes), "epoch": binding.Epoch, "created_at": binding.CreatedAt, "revoked_at": binding.RevokedAt})
	}
	c.JSON(200, gin.H{"items": rows, "total": total, "page": page, "page_size": 30})
}

func (h *IntegrationHandler) AdminAudits(c *gin.Context) {
	if _, err := uuid.Parse(c.Param("id")); err != nil {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
		return
	}
	var rows []models.IntegrationAudit
	if err := h.db.WithContext(c.Request.Context()).Where("binding_id = ?", c.Param("id")).Order("id DESC").Limit(50).Find(&rows).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	result := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		result = append(result, gin.H{"event": row.Event, "actor_id": row.ActorID, "reason": row.Reason, "created_at": row.CreatedAt})
	}
	c.JSON(200, gin.H{"items": result, "limit": 50, "note": "仅最近50条元数据，不含成绩、二课正文或凭证。"})
}

func (h *IntegrationHandler) AdminRestrict(c *gin.Context) {
	if _, err := uuid.Parse(c.Param("id")); err != nil {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
		return
	}
	var input struct {
		Epoch  uint     `json:"expected_epoch"`
		Scopes []string `json:"scopes"`
		Revoke bool     `json:"revoke"`
		Reason string   `json:"reason"`
	}
	if decodeStrictJSON(c, &input, 4096) != nil || len(strings.TrimSpace(input.Reason)) < 3 || len(input.Reason) > 240 || input.Epoch == 0 {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
		return
	}
	if err := h.auth.RestrictBinding(c.Request.Context(), c.GetUint("user_id"), c.Param("id"), input.Epoch, input.Scopes, input.Revoke, strings.TrimSpace(input.Reason)); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"message": "已限制授权，旧凭证已失效。新增或恢复权限须本人重新授权。"})
}
