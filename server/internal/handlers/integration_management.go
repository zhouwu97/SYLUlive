package handlers

import (
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"shenliyuan/internal/models"
)

const integrationAdminPageSize = 30

// AdminBindings 只返回授权元数据，不含成绩、二课正文或任何凭证。
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
	if err := query.Order("created_at DESC, id DESC").Limit(integrationAdminPageSize).Offset((page - 1) * integrationAdminPageSize).Find(&bindings).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	// 一次读取本页昵称，避免逐行查询；用户被删除时昵称留空，不让整页失败。
	owners := make([]uint, 0, len(bindings))
	for _, binding := range bindings {
		owners = append(owners, binding.OwnerID)
	}
	nicknames := map[uint]string{}
	if len(owners) > 0 {
		var users []struct {
			ID       uint
			Nickname string
		}
		if err := h.db.WithContext(c.Request.Context()).Model(&models.User{}).Select("id, nickname").Where("id IN ?", owners).Find(&users).Error; err != nil {
			writeIntegrationError(c, err, false)
			return
		}
		for _, user := range users {
			nicknames[user.ID] = user.Nickname
		}
	}
	rows := make([]gin.H, 0, len(bindings))
	for _, binding := range bindings {
		rows = append(rows, gin.H{"binding_id": binding.ID, "nickname": nicknames[binding.OwnerID], "installation_name": binding.InstallationName, "state": binding.State, "scopes": strings.Fields(binding.Scopes), "epoch": binding.Epoch, "created_at": binding.CreatedAt, "revoked_at": binding.RevokedAt})
	}
	c.JSON(200, gin.H{"items": rows, "total": total, "page": page, "page_size": integrationAdminPageSize, "personal_data_enabled": h.options.PersonalDataEnabled})
}

// AdminAudits 只给出最近 50 条事件元数据。
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

// AdminRestrict 只允许缩减或撤销；新增或恢复权限必须由用户本人重新授权。
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
	if decodeStrictJSON(c, &input, 4096) != nil || len([]rune(strings.TrimSpace(input.Reason))) < 3 || len([]rune(input.Reason)) > 240 || input.Epoch == 0 {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_request"})
		return
	}
	if err := h.auth.RestrictBinding(c.Request.Context(), c.GetUint("user_id"), c.Param("id"), input.Epoch, input.Scopes, input.Revoke, strings.TrimSpace(input.Reason)); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"message": "已限制授权，旧凭证已失效。新增或恢复权限须本人重新授权。"})
}
