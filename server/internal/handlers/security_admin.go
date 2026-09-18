package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// SecurityAdminHandler 提供独立于 AdminLog 的攻击事件查询和临时处置接口。
type SecurityAdminHandler struct {
	db                   *gorm.DB
	security             *services.SecurityEventService
	securityBlockEnabled bool
	trustedProxyCIDRs    []string
	attributionValidFrom string
	attributionCutoff    time.Time
}

func NewSecurityAdminHandler(db *gorm.DB, security *services.SecurityEventService) *SecurityAdminHandler {
	return &SecurityAdminHandler{db: db, security: security}
}

// SetProtectionConfig 将部署层的真实 IP 与封禁开关状态暴露给安全中心，便于管理员确认防护是否真正生效。
func (h *SecurityAdminHandler) SetProtectionConfig(blockEnabled bool, trustedProxyCIDRs []string, attributionValidFrom string) {
	h.securityBlockEnabled = blockEnabled
	h.trustedProxyCIDRs = append([]string(nil), trustedProxyCIDRs...)
	h.attributionValidFrom = attributionValidFrom
	h.attributionCutoff = time.Time{}
	if parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(attributionValidFrom)); err == nil {
		h.attributionCutoff = parsed
	}
}

type securityEventResponse struct {
	ID                        uint       `json:"id"`
	EventType                 string     `json:"event_type"`
	Severity                  string     `json:"severity"`
	Status                    string     `json:"status"`
	Route                     string     `json:"route"`
	Method                    string     `json:"method"`
	SourceFingerprint         string     `json:"source_fingerprint"`
	SourceKey                 string     `json:"source_key,omitempty"`
	InstallationSeen          bool       `json:"installation_seen"`
	ActorUserID               *uint      `json:"actor_user_id,omitempty"`
	TargetType                string     `json:"target_type"`
	TargetMasked              string     `json:"target_masked"`
	RequestIDSample           string     `json:"request_id_sample"`
	AttemptCount              int        `json:"attempt_count"`
	BlockedCount              int        `json:"blocked_count"`
	MailSentCount             int        `json:"mail_sent_count"`
	PasswordResetSuccessCount int        `json:"password_reset_success_count"`
	SourceAttributionValid    bool       `json:"source_attribution_valid"`
	Action                    string     `json:"action"`
	MetadataJSON              string     `json:"metadata_json,omitempty"`
	FirstSeenAt               time.Time  `json:"first_seen_at"`
	LastSeenAt                time.Time  `json:"last_seen_at"`
	ResolvedAt                *time.Time `json:"resolved_at,omitempty"`
	ResolvedBy                *uint      `json:"resolved_by,omitempty"`
	ResolutionNote            string     `json:"resolution_note,omitempty"`
}

func (h *SecurityAdminHandler) Overview(c *gin.Context) {
	rangeName := "24h"
	since := time.Now().Add(-24 * time.Hour)
	if raw := strings.TrimSpace(c.Query("range")); raw != "" {
		rangeName = raw
		switch raw {
		case "1h":
			since = time.Now().Add(-time.Hour)
		case "7d":
			since = time.Now().Add(-7 * 24 * time.Hour)
		case "24h":
		default:
			c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的统计时间范围"})
			return
		}
	}
	base := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ?", since)
	var total, activeHigh, blocked, affectedUsers, uniqueSources, emailAbuse, loginAbuse, critical, mailSent, resetSuccess int64
	if err := base.Count(&total).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND status = ? AND severity IN ?", since, models.SecurityEventStatusActive, []string{models.SecuritySeverityHigh, models.SecuritySeverityCritical}).Count(&activeHigh).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ?", since).Select("COALESCE(SUM(blocked_count), 0)").Scan(&blocked).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND target_hash <> ''", since).Distinct("target_hash").Count(&affectedUsers).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND source_ip_hash <> ''", since).Distinct("source_ip_hash").Count(&uniqueSources).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND event_type IN ?", since, []string{"email_target_flood", "password_reset_spray", "verification_spray", "verification_source_rate", "verification_code_bruteforce", "password_reset_activity", "verification_activity"}).Select("COALESCE(SUM(attempt_count), 0)").Scan(&emailAbuse).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND event_type IN ?", since, []string{"login_bruteforce", "login_password_spray"}).Select("COALESCE(SUM(attempt_count), 0)").Scan(&loginAbuse).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND severity = ?", since, models.SecuritySeverityCritical).Count(&critical).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ?", since).Select("COALESCE(SUM(mail_sent_count), 0)").Scan(&mailSent).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ?", since).Select("COALESCE(SUM(password_reset_success_count), 0)").Scan(&resetSuccess).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"range": rangeName, "active_high_count": activeHigh, "total_events": total,
		"blocked_requests": blocked, "affected_targets": affectedUsers, "affected_users": affectedUsers, "unique_sources": uniqueSources,
		"email_abuse_count": emailAbuse, "login_abuse_count": loginAbuse, "critical_count": critical,
		"mail_sent_count": mailSent, "password_reset_success_count": resetSuccess,
		"protection": gin.H{
			"client_ip_identification":      map[bool]string{true: "configured", false: "not_configured"}[len(h.trustedProxyCIDRs) > 0],
			"trusted_proxy_cidrs":           h.trustedProxyCIDRs,
			"security_block":                map[bool]string{true: "enabled", false: "disabled"}[h.securityBlockEnabled],
			"security_block_schema":         map[bool]string{true: "ready", false: "missing"}[h.db.Migrator().HasTable(&models.SecurityBlock{})],
			"security_event_collection":     map[bool]string{true: "ready", false: "missing"}[h.db.Migrator().HasTable(&models.SecurityEvent{})],
			"verification_daily_limit":      "enabled",
			"source_attribution_valid_from": h.attributionValidFrom,
		},
	})
}

func (h *SecurityAdminHandler) ListEvents(c *gin.Context) {
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	if page <= 0 {
		page = 1
	}
	query := h.db.Model(&models.SecurityEvent{}).Order("last_seen_at DESC, id DESC")
	if eventType := strings.TrimSpace(c.Query("event_type")); eventType != "" && eventType != "all" {
		query = query.Where("event_type = ?", eventType)
	}
	if severity := strings.TrimSpace(c.Query("severity")); severity != "" && severity != "all" {
		query = query.Where("severity = ?", severity)
	}
	if status := strings.TrimSpace(c.Query("status")); status != "" && status != "all" {
		query = query.Where("status = ?", status)
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	var events []models.SecurityEvent
	if err := query.Offset((page - 1) * limit).Limit(limit).Find(&events).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	isSuper := c.GetString("role") == string(models.RoleSuperAdmin)
	items := make([]securityEventResponse, 0, len(events))
	for _, event := range events {
		items = append(items, h.securityEventDTO(event, isSuper))
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "total": total, "page": page, "limit": limit})
}

func (h *SecurityAdminHandler) GetEvent(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的安全事件 ID"})
		return
	}
	var event models.SecurityEvent
	if err := h.db.First(&event, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"error": "安全事件不存在"})
		} else {
			h.securityDatabaseError(c)
		}
		return
	}
	c.JSON(http.StatusOK, h.securityEventDTO(event, c.GetString("role") == string(models.RoleSuperAdmin)))
}

type securityResolutionInput struct {
	Note string `json:"note"`
}

func (h *SecurityAdminHandler) Resolve(c *gin.Context) {
	h.updateEventStatus(c, models.SecurityEventStatusResolved)
}

func (h *SecurityAdminHandler) FalsePositive(c *gin.Context) {
	h.updateEventStatus(c, models.SecurityEventStatusFalsePositive)
}

func (h *SecurityAdminHandler) updateEventStatus(c *gin.Context, status string) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的安全事件 ID"})
		return
	}
	var input securityResolutionInput
	_ = c.ShouldBindJSON(&input)
	input.Note = truncateSecurityNote(input.Note)
	operatorID := c.GetUint("user_id")
	now := time.Now()
	var event models.SecurityEvent
	if err := h.db.First(&event, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "安全事件不存在"})
		return
	}
	if err := h.db.Model(&event).Updates(map[string]interface{}{
		"status": status, "resolved_at": now, "resolved_by": operatorID, "resolution_note": input.Note,
	}).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	h.writeSecurityAdminLog(c, "security_event_"+status, strconv.FormatUint(id, 10), input.Note)
	c.JSON(http.StatusOK, gin.H{"message": "安全事件状态已更新", "status": status})
}

type securityBlockInput struct {
	SourceKey   string `json:"source_key" binding:"required"`
	RoutePrefix string `json:"route_prefix"`
	DurationMin int    `json:"duration_minutes" binding:"required"`
	Reason      string `json:"reason"`
}

func (h *SecurityAdminHandler) ListBlocks(c *gin.Context) {
	var blocks []models.SecurityBlock
	if err := h.db.Where("revoked_at IS NULL AND expires_at > ?", time.Now()).Order("expires_at ASC").Limit(200).Find(&blocks).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	items := make([]gin.H, 0, len(blocks))
	for _, block := range blocks {
		items = append(items, gin.H{
			"id": block.ID, "scope_type": block.ScopeType,
			"source_fingerprint": services.MaskSecurityFingerprint(block.ScopeValue),
			"source_key":         block.ScopeValue, "route_prefix": block.RoutePrefix,
			"reason": block.Reason, "expires_at": block.ExpiresAt, "created_at": block.CreatedAt,
		})
	}
	c.JSON(http.StatusOK, items)
}

func (h *SecurityAdminHandler) CreateBlock(c *gin.Context) {
	if !h.securityBlockEnabled {
		c.JSON(http.StatusServiceUnavailable, gin.H{"code": "security_block_disabled", "error": "来源封禁功能当前未启用"})
		return
	}
	var input securityBlockInput
	if err := c.ShouldBindJSON(&input); err != nil || !isAllowedBlockDuration(input.DurationMin) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "封禁时长只能是 15 分钟、1 小时或 24 小时"})
		return
	}
	key := strings.TrimSpace(input.SourceKey)
	if len(key) != 64 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "来源指纹无效"})
		return
	}
	var sourceEvent models.SecurityEvent
	if err := h.db.Where("source_ip_hash = ?", key).Order("last_seen_at DESC").First(&sourceEvent).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusConflict, gin.H{"code": "security_source_not_found", "error": "来源指纹没有可核验的安全事件"})
			return
		}
		h.securityDatabaseError(c)
		return
	}
	if !sourceEvent.SourceAttributionValid || (!h.attributionCutoff.IsZero() && sourceEvent.FirstSeenAt.Before(h.attributionCutoff)) {
		c.JSON(http.StatusConflict, gin.H{"code": "security_source_attribution_invalid", "error": "历史来源归因不可信，不能创建封禁"})
		return
	}
	prefix := strings.TrimSpace(input.RoutePrefix)
	if prefix != "" && (!strings.HasPrefix(prefix, "/api/") || len(prefix) > 160) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "路由范围无效"})
		return
	}
	now := time.Now()
	block := models.SecurityBlock{
		ScopeType: "ip_hash", ScopeValue: key, RoutePrefix: prefix,
		Reason: truncateSecurityNote(input.Reason), ExpiresAt: now.Add(time.Duration(input.DurationMin) * time.Minute),
		CreatedBy: c.GetUint("user_id"), CreatedAt: now,
	}
	if err := h.db.Create(&block).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	h.writeSecurityAdminLog(c, "security_block_created", services.MaskSecurityFingerprint(key), block.Reason)
	c.JSON(http.StatusCreated, gin.H{"id": block.ID, "expires_at": block.ExpiresAt})
}

func (h *SecurityAdminHandler) RevokeBlock(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的封禁 ID"})
		return
	}
	now := time.Now()
	operatorID := c.GetUint("user_id")
	result := h.db.Model(&models.SecurityBlock{}).Where("id = ? AND revoked_at IS NULL", id).Updates(map[string]interface{}{"revoked_at": now, "revoked_by": operatorID})
	if result.Error != nil {
		h.securityDatabaseError(c)
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "封禁不存在或已解除"})
		return
	}
	h.writeSecurityAdminLog(c, "security_block_revoked", strconv.FormatUint(id, 10), "")
	c.JSON(http.StatusOK, gin.H{"message": "封禁已解除"})
}

func (h *SecurityAdminHandler) securityEventDTO(event models.SecurityEvent, isSuper bool) securityEventResponse {
	attributionValid := event.SourceAttributionValid
	if !h.attributionCutoff.IsZero() && event.FirstSeenAt.Before(h.attributionCutoff) {
		// 迁移前的事件可以继续用于相对关联，但不能被误解为可信的真实 IP 归因。
		attributionValid = false
	}
	result := securityEventResponse{
		ID: event.ID, EventType: event.EventType, Severity: event.Severity, Status: event.Status,
		Route: event.Route, Method: event.Method, SourceFingerprint: services.MaskSecurityFingerprint(event.SourceIPHash),
		InstallationSeen: event.InstallationHash != "", ActorUserID: event.ActorUserID,
		TargetType: event.TargetType, TargetMasked: event.TargetMasked, RequestIDSample: event.RequestIDSample,
		AttemptCount: event.AttemptCount, BlockedCount: event.BlockedCount, MailSentCount: event.MailSentCount,
		PasswordResetSuccessCount: event.PasswordResetSuccessCount, SourceAttributionValid: attributionValid, Action: event.Action,
		MetadataJSON: event.MetadataJSON, FirstSeenAt: event.FirstSeenAt, LastSeenAt: event.LastSeenAt,
		ResolvedAt: event.ResolvedAt, ResolvedBy: event.ResolvedBy, ResolutionNote: event.ResolutionNote,
	}
	if isSuper {
		result.SourceKey = event.SourceIPHash
	}
	return result
}

func (h *SecurityAdminHandler) writeSecurityAdminLog(c *gin.Context, action, target, detail string) {
	adminID := c.GetUint("user_id")
	var admin models.User
	_ = h.db.Select("nickname").First(&admin, adminID).Error
	_ = h.db.Create(&models.AdminLog{AdminID: adminID, AdminName: admin.Nickname, Action: action, Target: target, Detail: truncateSecurityNote(detail)}).Error
}

func (h *SecurityAdminHandler) securityDatabaseError(c *gin.Context) {
	c.JSON(http.StatusInternalServerError, gin.H{"error": "安全中心暂时不可用"})
}

func isAllowedBlockDuration(minutes int) bool {
	return minutes == 15 || minutes == 60 || minutes == 1440
}

func truncateSecurityNote(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 500 {
		return value[:500]
	}
	return value
}
