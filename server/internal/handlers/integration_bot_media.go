package handlers

import (
	"github.com/gin-gonic/gin"
	"net/http"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
	"time"
)

func (h *IntegrationHandler) SetBotUploader(uploader *UploadHandler) { h.botUploader = uploader }

func (h *IntegrationHandler) BotCapabilities(c *gin.Context) {
	b := c.MustGet("integration_binding").(models.IntegrationBinding)
	if len(c.Request.URL.Query()) != 0 || !services.IntegrationHasScope(b, services.IntegrationAutoPostScope) {
		writeIntegrationError(c, &services.IntegrationError{Code: "insufficient_scope", Status: 403}, false)
		return
	}
	if !h.options.AutoPostEnabled || !h.options.ProposalsEnabled {
		c.JSON(200, gin.H{"auto_post": false, "media_upload": false})
		return
	}
	if _, err := h.actions().BotPublicationActor(c.Request.Context(), b, false); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	_, imageError := h.actions().BotUploadActor(c.Request.Context(), b)
	c.JSON(200, gin.H{"auto_post": true, "media_upload": h.botUploader != nil && imageError == nil})
}

func (h *IntegrationHandler) AutoPost(c *gin.Context) {
	if !h.options.AutoPostEnabled || !h.options.ProposalsEnabled {
		writeIntegrationError(c, &services.IntegrationError{Code: "bot_post_disabled", Status: 403}, false)
		return
	}
	var p services.IntegrationProposal
	if decodeStrictJSON(c, &p, 20<<10) != nil {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_bot_post"})
		return
	}
	a, err := h.actions().AutoPost(c.Request.Context(), c.MustGet("integration_binding").(models.IntegrationBinding), p)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"state": a.State, "action_id": a.ID, "post_id": a.PostID})
}

func (h *IntegrationHandler) BotUpload(c *gin.Context) {
	if !h.options.AutoPostEnabled || !h.options.ProposalsEnabled {
		writeIntegrationError(c, &services.IntegrationError{Code: "bot_post_disabled", Status: 403}, false)
		return
	}
	if h.botUploader == nil {
		c.AbortWithStatusJSON(503, gin.H{"code": "bot_media_unavailable"})
		return
	}
	b := c.MustGet("integration_binding").(models.IntegrationBinding)
	actor, err := h.actions().BotUploadActor(c.Request.Context(), b)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	if err := h.auth.AllowRequest(c.Request.Context(), "bot_media", b.ID, 6, 24*time.Hour); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	if len(c.Request.URL.Query()) != 0 {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_bot_media"})
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, (4<<20)+(64<<10))
	if err := c.Request.ParseMultipartForm(1 << 20); err != nil {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_bot_media"})
		return
	}
	defer c.Request.MultipartForm.RemoveAll()
	form := c.Request.MultipartForm
	if len(form.Value) != 0 || len(form.File) != 1 || len(form.File["file"]) != 1 || form.File["file"][0].Size > 4<<20 {
		c.AbortWithStatusJSON(422, gin.H{"code": "invalid_bot_media"})
		return
	}
	// 沿用普通上传的真实格式/尺寸校验、哈希去重、磁盘配额和临时私有文件清理。
	// 这里只切换到已验证的独立 bot，模型没有指定上传者或复用 App JWT 的入口。
	c.Set("user_id", actor)
	h.botUploader.Upload(c)
}
