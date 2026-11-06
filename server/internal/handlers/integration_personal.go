package handlers

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"strconv"
)

func (h *IntegrationHandler) UploadGrades(c *gin.Context) {
	if !h.personalEnabled(c) {
		return
	}
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
		if !h.personalEnabled(c) {
			return
		}
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

func (h *IntegrationHandler) personalEnabled(c *gin.Context) bool {
	if !h.options.PersonalDataEnabled {
		writeIntegrationError(c, &services.IntegrationError{Code: "personal_queries_disabled", Status: 403}, false)
		return false
	}
	return true
}
