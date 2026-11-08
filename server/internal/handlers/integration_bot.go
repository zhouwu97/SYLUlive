package handlers

import (
	"errors"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func (h *IntegrationHandler) managedBotView(owner uint) (gin.H, error) {
	var bot models.ManagedBot
	err := h.db.Where("owner_id = ?", owner).Take(&bot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var actor, creator models.User
	if err := h.db.Select("id", "nickname", "avatar").First(&actor, bot.UserID).Error; err != nil {
		return nil, err
	}
	if err := h.db.Select("id", "nickname").First(&creator, owner).Error; err != nil {
		return nil, err
	}
	return gin.H{"bot_user_id": bot.UserID, "name": strings.TrimPrefix(actor.Nickname, "[AI] "), "avatar": actor.Avatar, "enabled": bot.Enabled, "owner": gin.H{"id": creator.ID, "nickname": creator.Nickname}, "policy": services.ManagedBotPolicy(bot)}, nil
}

func (h *IntegrationHandler) BotStatus(c *gin.Context) {
	owner := c.GetUint("user_id")
	var bindings []models.IntegrationBinding
	if err := h.db.Where("owner_id = ? AND state = ?", owner, "active").Find(&bindings).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	authorized := false
	postAuthorized := false
	for _, binding := range bindings {
		if h.auth.CheckBinding(c.Request.Context(), binding) != nil {
			continue
		}
		authorized = authorized || services.IntegrationHasScope(binding, services.IntegrationAutoReplyScope)
		postAuthorized = postAuthorized || services.IntegrationHasScope(binding, services.IntegrationAutoPostScope)
	}
	var sections []models.WaterSection
	if err := h.db.Select("slug", "title", "status", "sensitive_level").Where("status = ?", "active").Order("sort_order ASC, id ASC").Limit(100).Find(&sections).Error; err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	choices := []gin.H{}
	for _, section := range sections {
		if services.ManagedBotSectionAllowed(section) {
			choices = append(choices, gin.H{"slug": section.Slug, "name": section.Title})
		}
	}
	bot, err := h.managedBotView(owner)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	runtime, err := h.actions().BotRuntimeStatus(c.Request.Context(), owner)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"bot": bot, "runtime_supported": true, "runtime": runtime, "policy_supported": true, "sections": choices, "auto_reply_server_enabled": h.options.AutoReplyEnabled, "auto_reply_authorized": authorized, "auto_post_server_enabled": h.options.AutoPostEnabled, "auto_post_authorized": postAuthorized})
}

func (h *IntegrationHandler) ManageBot(c *gin.Context) {
	var input services.ManagedBotUpdate
	if decodeStrictJSON(c, &input, 8192) != nil {
		writeIntegrationError(c, &services.IntegrationError{Code: "invalid_request", Status: 422}, false)
		return
	}
	// The original client included the unchanged name when pausing; do not turn a pause into a privileged edit.
	if !input.Enabled && input.Avatar == nil && input.Policy == nil && input.Name != nil {
		var bot models.ManagedBot
		if h.db.Where("owner_id = ?", c.GetUint("user_id")).Take(&bot).Error == nil {
			var actor models.User
			if h.db.Select("nickname").First(&actor, bot.UserID).Error == nil && strings.TrimSpace(*input.Name) == strings.TrimPrefix(actor.Nickname, "[AI] ") {
				input.Name = nil
			}
		}
	}
	if (input.Enabled || input.Name != nil || input.Avatar != nil || input.Policy != nil) && !h.recent(c) {
		return
	}
	_, err := h.actions().UpdateManagedBot(c.Request.Context(), c.GetUint("user_id"), input)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	bot, err := h.managedBotView(c.GetUint("user_id"))
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"bot": bot})
}

// BotPolicy exposes only this binding's bot controls. No creator private profile or chat memory is included.
func (h *IntegrationHandler) BotPolicy(c *gin.Context) {
	b := c.MustGet("integration_binding").(models.IntegrationBinding)
	if !services.IntegrationHasScope(b, services.IntegrationReadScope) {
		writeIntegrationError(c, &services.IntegrationError{Code: "insufficient_scope", Status: 403}, false)
		return
	}
	var bot models.ManagedBot
	err := h.db.Where("owner_id = ?", b.OwnerID).Take(&bot).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(200, gin.H{"bot": nil, "runtime_supported": true})
		return
	}
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	if err := h.auth.CheckBinding(c.Request.Context(), b); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"runtime_supported": true, "binding": gin.H{"binding_id": b.ID, "epoch": b.Epoch}, "bot": gin.H{"bot_user_id": bot.UserID, "revision": bot.Revision, "enabled": bot.Enabled, "policy": services.ManagedBotPolicy(bot)}, "auto_reply_server_enabled": h.options.AutoReplyEnabled, "auto_reply_authorized": services.IntegrationHasScope(b, services.IntegrationAutoReplyScope), "auto_post_server_enabled": h.options.AutoPostEnabled, "auto_post_authorized": services.IntegrationHasScope(b, services.IntegrationAutoPostScope)})
}

func (h *IntegrationHandler) BotRuntimeHeartbeat(c *gin.Context) {
	var input services.BotRuntimeHeartbeat
	if len(c.Request.URL.Query()) != 0 || decodeStrictJSON(c, &input, 2048) != nil {
		writeIntegrationError(c, &services.IntegrationError{Code: "invalid_bot_runtime", Status: 422}, false)
		return
	}
	binding := c.MustGet("integration_binding").(models.IntegrationBinding)
	if err := h.auth.AllowRequest(c.Request.Context(), "bot_runtime", binding.ID, 12, time.Minute); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	if err := h.actions().RecordBotRuntime(c.Request.Context(), binding, input); err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"accepted": true, "lease_seconds": int(services.BotRuntimeLease.Seconds())})
}

func (h *IntegrationHandler) BotRuntimeStatus(c *gin.Context) {
	if len(c.Request.URL.Query()) != 0 {
		writeIntegrationError(c, &services.IntegrationError{Code: "invalid_request", Status: 422}, false)
		return
	}
	runtime, err := h.actions().BotRuntimeStatus(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"runtime": runtime})
}

func (h *IntegrationHandler) AutoReply(c *gin.Context) {
	if !h.options.AutoReplyEnabled {
		writeIntegrationError(c, &services.IntegrationError{Code: "bot_reply_disabled", Status: 403}, false)
		return
	}
	var p services.IntegrationProposal
	if decodeStrictJSON(c, &p, 4096) != nil {
		writeIntegrationError(c, &services.IntegrationError{Code: "invalid_bot_reply", Status: 422}, false)
		return
	}
	a, err := h.actions().AutoReply(c.Request.Context(), c.MustGet("integration_binding").(models.IntegrationBinding), p)
	if err != nil {
		writeIntegrationError(c, err, false)
		return
	}
	c.JSON(200, gin.H{"state": a.State, "action_id": a.ID, "post_id": a.PostID, "reply_id": a.ReplyID})
}
