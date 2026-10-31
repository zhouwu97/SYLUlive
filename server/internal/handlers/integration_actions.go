package handlers

import (
	"github.com/gin-gonic/gin"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func (h *IntegrationHandler) actions() *services.IntegrationActionService {
	return &services.IntegrationActionService{Auth: h.auth, ValidSticker: IsValidStickerID, AfterReplyCommit: h.options.AfterReplyCommit}
}
func (h *IntegrationHandler) Propose(c *gin.Context) {
	b := c.MustGet("integration_binding").(models.IntegrationBinding)
	if !h.options.ProposalsEnabled || !services.IntegrationHasScope(b, services.IntegrationProposeScope) {
		writeIntegrationError(c, &services.IntegrationError{Code: "proposals_unavailable", Status: 403}, false)
		return
	}
	var p services.IntegrationProposal
	if decodeStrictJSON(c, &p, 65536) != nil {
		writeIntegrationError(c, &services.IntegrationError{Code: "invalid_proposal", Status: 422}, false)
		return
	}
	a, err := h.actions().Propose(c.Request.Context(), b, p)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"action_id": a.ID, "state": a.State, "post_id": a.PostID, "reply_id": a.ReplyID, "review_uri": h.options.PublicOrigin + "/web/connected-apps/actions/" + a.ID, "expires_at": a.ExpiresAt})
}
func (h *IntegrationHandler) ActionStatus(c *gin.Context) {
	b := c.MustGet("integration_binding").(models.IntegrationBinding)
	if !services.IntegrationHasScope(b, services.IntegrationActionScope) {
		writeIntegrationError(c, &services.IntegrationError{Code: "insufficient_scope", Status: 403}, false)
		return
	}
	result, err := h.actions().Preview(c.Request.Context(), b.OwnerID, c.Param("id"), &b)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, result)
}
func (h *IntegrationHandler) ActionPreview(c *gin.Context) {
	if !h.recent(c) {
		return
	}
	result, err := h.actions().Preview(c.Request.Context(), c.GetUint("user_id"), c.Param("id"), nil)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(200, result)
}
func (h *IntegrationHandler) ActionDecision(c *gin.Context) {
	if !h.recent(c) {
		return
	}
	var d services.IntegrationActionDecision
	if decodeStrictJSON(c, &d, 4096) != nil {
		writeIntegrationError(c, &services.IntegrationError{Code: "invalid_request", Status: 422}, false)
		return
	}
	if d.Allow && !h.options.OwnerPublishEnabled {
		writeIntegrationError(c, &services.IntegrationError{Code: "owner_publish_disabled", Status: 403}, false)
		return
	}
	result, err := h.actions().Decide(c.Request.Context(), c.GetUint("user_id"), c.Param("id"), d)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"action": result})
}
func (h *IntegrationHandler) Sections(c *gin.Context) {
	b := c.MustGet("integration_binding").(models.IntegrationBinding)
	if !services.IntegrationHasScope(b, services.IntegrationReadScope) {
		writeIntegrationError(c, &services.IntegrationError{Code: "insufficient_scope", Status: 403}, false)
		return
	}
	var sections []struct {
		Slug  string `json:"slug"`
		Title string `json:"title"`
	}
	if err := h.db.WithContext(c.Request.Context()).Model(&models.WaterSection{}).Select("slug", "title").Where("status = ?", "active").Order("sort_order ASC, id ASC").Limit(100).Find(&sections).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"sections": sections})
}
