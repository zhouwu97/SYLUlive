package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// actionableScope 把查询限制在「需要管理员处置」的事件上。
//
// 判定规则集中在 models.SecurityEventActionable：审计流水（正常验证码、正常改密、
// 单次密码输错、冷却拦截、已生效的来源封禁计数）不属于待处置，未知类型默认算待处置。
// 这里用 NOT IN 白名单实现，避免每个查询各写一份类型清单。
func actionableScope(query *gorm.DB) *gorm.DB {
	auditTypes := models.SecurityAuditEventTypes()
	if len(auditTypes) == 0 {
		// 没有登记任何审计类型时，全部事件都算待处置：宁可多显示，不能漏。
		return query
	}
	return query.Where("event_type NOT IN ?", auditTypes)
}

// auditScope 是 actionableScope 的反面，供「只看审计流水」的调查场景使用。
func auditScope(query *gorm.DB) *gorm.DB {
	auditTypes := models.SecurityAuditEventTypes()
	if len(auditTypes) == 0 {
		return query.Where("1 = 0")
	}
	return query.Where("event_type IN ?", auditTypes)
}

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

	// Actionable 由事件类型推导（models.SecurityEventActionable），表示这条记录是否
	// 需要管理员处置。审计流水（正常验证码、正常改密、单次密码输错、冷却拦截、
	// 已生效的来源封禁计数）为 false，默认列表不展示它们，避免待办被正常流量刷满。
	Actionable bool `json:"actionable"`
}

// protectionLayerState 把一层防护的「配置态」和「运行态」分开上报。
//
// configured 回答「代码与部署里有没有这层保护」，runtime 回答「它此刻是否真的在工作」。
// 二者过去被压成一个 enabled/ready，管理员看到一排绿色时无法分辨自己拿到的是哪种保证。
func protectionLayerState(configured bool, runtime, reason string, detail map[string]interface{}) gin.H {
	state := gin.H{"configured": configured, "runtime": runtime}
	if reason != "" {
		state["reason"] = reason
	}
	if len(detail) > 0 {
		state["detail"] = detail
	}
	return state
}

// securityEventCollectionState 判断安全事件采集的真实运行态。
//
// 早期实现只看 `HasTable(&SecurityEvent{})`：表存在即 ready。但业务侧写事件统一
// `_ = Record(...)` 忽略错误，表在而写入一直失败时，攻击记录会整批丢失且无人察觉。
// 现在以实际 UPSERT 的成败为准；表缺失单独判 unavailable，没有比“写不进去”更严重的降级。
func (h *SecurityAdminHandler) securityEventCollectionState() gin.H {
	snapshot := h.security.EventWriteHealth()
	if !h.db.Migrator().HasTable(&models.SecurityEvent{}) {
		return protectionLayerState(true, services.SecurityLayerUnavailable, "security_event_table_missing", snapshot.Detail())
	}
	runtime := snapshot.Status()
	reason := ""
	if runtime != services.SecurityLayerReady {
		reason = "last_write_failed"
		if runtime == services.SecurityLayerUnknown {
			reason = "not_written_since_start"
		}
	}
	return protectionLayerState(true, runtime, reason, snapshot.Detail())
}

func (h *SecurityAdminHandler) securityBlockState() gin.H {
	if !h.securityBlockEnabled {
		return protectionLayerState(false, services.SecurityLayerNotConfigured,
			"block_switch_off", h.security.BlockCheckHealth().Detail())
	}
	snapshot := h.security.BlockCheckHealth()
	if !h.db.Migrator().HasTable(&models.SecurityBlock{}) {
		return protectionLayerState(true, services.SecurityLayerUnavailable,
			"security_block_table_missing", snapshot.Detail())
	}
	runtime := snapshot.Status()
	// 同时读 degraded 标记：/health 就是按它判定 fail-open 的，两处必须给出同一结论，
	// 否则会出现「/health 说降级、安全中心显示正常」。
	if runtime == services.SecurityLayerReady && h.security.SecurityBlockDegraded() {
		runtime = services.SecurityLayerDegraded
	}
	reason := ""
	switch runtime {
	case services.SecurityLayerDegraded, services.SecurityLayerUnavailable:
		reason = "block_lookup_failed_fail_open"
	case services.SecurityLayerUnknown:
		reason = "not_queried_since_start"
	}
	return protectionLayerState(true, runtime, reason, snapshot.Detail())
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
	var actionableHigh, actionablePending int64
	if err := base.Count(&total).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND status = ? AND severity IN ?", since, models.SecurityEventStatusActive, []string{models.SecuritySeverityHigh, models.SecuritySeverityCritical}).Count(&activeHigh).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	// 首页「高危待处理」的正确口径：待处置 + 未处理 + 高危/严重。
	//
	// active_high_count 是早期字段，按 status+severity 统计，会把已由封禁层处置掉的
	// security_blocked_request 也算进去，于是卡片上的数字远大于列表里真正要处理的事。
	// 新字段把 actionable 一并纳入，客户端首页应当使用它；旧字段保留以兼容未升级客户端。
	highSeverities := []string{models.SecuritySeverityHigh, models.SecuritySeverityCritical}
	if err := actionableScope(h.db.Model(&models.SecurityEvent{}).
		Where("last_seen_at >= ? AND status = ? AND severity IN ?", since, models.SecurityEventStatusActive, highSeverities)).
		Count(&actionableHigh).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	if err := actionableScope(h.db.Model(&models.SecurityEvent{}).
		Where("last_seen_at >= ? AND status = ?", since, models.SecurityEventStatusActive)).
		Count(&actionablePending).Error; err != nil {
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
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND event_type IN ?", since, []string{"email_target_flood", "password_reset_spray", "verification_spray", "verification_source_rate", "verification_code_bruteforce", "verification_mail_delivery_failed", "password_reset_activity", "verification_activity"}).Select("COALESCE(SUM(attempt_count), 0)").Scan(&emailAbuse).Error; err != nil {
		h.securityDatabaseError(c)
		return
	}
	// 登录侧失败总量：普通输错（login_failed）、已锁定的暴力尝试、多账号扫描都要计入，
	// 否则把普通失败降级为 login_failed 之后这个数字会凭空变小。
	if err := h.db.Model(&models.SecurityEvent{}).Where("last_seen_at >= ? AND event_type IN ?", since, []string{"login_failed", "login_bruteforce", "login_password_spray"}).Select("COALESCE(SUM(attempt_count), 0)").Scan(&loginAbuse).Error; err != nil {
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
	eventCollection := h.securityEventCollectionState()
	blockState := h.securityBlockState()
	c.JSON(http.StatusOK, gin.H{
		"range": rangeName, "active_high_count": activeHigh, "total_events": total,
		// 客户端首页口径：高危待处理 = 待处置 + 未处理 + 高危/严重。
		"actionable_high_count": actionableHigh, "actionable_pending_count": actionablePending,
		"blocked_requests": blocked, "affected_targets": affectedUsers, "affected_users": affectedUsers, "unique_sources": uniqueSources,
		"email_abuse_count": emailAbuse, "login_abuse_count": loginAbuse, "critical_count": critical,
		"mail_sent_count": mailSent, "password_reset_success_count": resetSuccess,
		"protection": gin.H{
			"client_ip_identification": map[bool]string{true: "configured", false: "not_configured"}[len(h.trustedProxyCIDRs) > 0],
			"trusted_proxy_cidrs":      h.trustedProxyCIDRs,
			// security_block 是**配置态**（开关），运行态在 security_block_state：
			// fail-open 期间查询失败会让这一层暂时给不出判断，只看开关会把「没拦住」读成「一切正常」。
			"security_block":        map[bool]string{true: "enabled", false: "disabled"}[h.securityBlockEnabled],
			"security_block_state":  blockState,
			"security_block_schema": map[bool]string{true: "ready", false: "missing"}[h.db.Migrator().HasTable(&models.SecurityBlock{})],
			// security_event_collection 的取值来自真实写入结果，不再是「表是否存在」。
			// 未升级客户端只把 ready 认成绿色，其余状态一律落到告警色：
			// 口径收窄时宁可让旧版本多报一次警，也不能继续假绿。
			"security_event_collection":       eventCollection["runtime"],
			"security_event_collection_state": eventCollection,
			"verification_daily_limit":        "enabled",
			"source_attribution_valid_from":   h.attributionValidFrom,
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
	// actionable=true 只看待处置，actionable=false 只看审计流水，缺省 / all 返回全部。
	// 客户端默认使用 true，避免正常验证码与正常改密把待办列表刷满。
	switch strings.ToLower(strings.TrimSpace(c.DefaultQuery("actionable", "all"))) {
	case "true", "1", "yes":
		query = actionableScope(query)
	case "false", "0", "no":
		query = auditScope(query)
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
	SourceKey string `json:"source_key" binding:"required"`
	// Scope 是封禁作用域：route（仅该路由）/ account（账号安全链路）/ all（全部敏感路由）。
	// 缺省时按 route 处理，但此时 route_prefix 必须显式给出。
	Scope       string `json:"scope"`
	RoutePrefix string `json:"route_prefix"`
	DurationMin int    `json:"duration_minutes" binding:"required"`
	// ConfirmGlobal 是 all 作用域的二次确认位。
	// 留空或 false 时任何请求都不能创建全站封禁，避免一次误点波及整个共享出口。
	ConfirmGlobal bool   `json:"confirm_global"`
	Reason        string `json:"reason"`
}

const (
	securityBlockScopeRoute   = "route"
	securityBlockScopeAccount = "account"
	securityBlockScopeAll     = "all"
)

var (
	errSecurityBlockScopeRequired   = errors.New("封禁作用域不能为空")
	errSecurityBlockScopeInvalid    = errors.New("不支持的封禁作用域")
	errSecurityBlockScopeNotRouted  = errors.New("该路由不在来源封禁覆盖范围内")
	errSecurityBlockGlobalUnconfirm = errors.New("全站封禁需要显式二次确认")
)

// resolveBlockScopes 把作用域解析成一组路由前缀，每个前缀写一条 SecurityBlock。
//
// 为什么必须显式：查询侧把**空 route_prefix** 当作「对所有敏感路由生效」，而客户端曾经
// 固定发送空 route_prefix。校园网、宿舍宽带和运营商 CGNAT 都是大量用户共用一个出口，
// 一次「临时封禁来源」就可能连坐一批正常同学。因此这里不再接受「空前缀 = 全站」的隐式默认：
//
//	route   -> 仅当前路由（默认，最小作用域）
//	account -> 登录 / 改密 / 注册验证码这一组账号与验证码接口
//	all     -> 全站，必须超级管理员显式二次确认
func resolveBlockScopes(input securityBlockInput) ([]string, error) {
	scope := strings.ToLower(strings.TrimSpace(input.Scope))
	prefix := strings.TrimSpace(input.RoutePrefix)
	if scope == "" {
		// 兼容未升级客户端：只给 route_prefix 时按「仅该路由」理解。
		// 空 route_prefix 不再默认全站，直接拒绝。
		if prefix == "" {
			return nil, errSecurityBlockScopeRequired
		}
		scope = securityBlockScopeRoute
	}
	switch scope {
	case securityBlockScopeRoute:
		if prefix == "" {
			return nil, errSecurityBlockScopeRequired
		}
		if len(prefix) > 160 || !strings.HasPrefix(prefix, "/api/") {
			return nil, errSecurityBlockScopeInvalid
		}
		if !middleware.SensitiveSecurityRoute(prefix) {
			// 非敏感路由本来就不查封禁表，接受它只会让管理员以为封禁生效了。
			return nil, errSecurityBlockScopeNotRouted
		}
		return []string{prefix}, nil
	case securityBlockScopeAccount:
		// 账号与验证码链路：撞库、账号接管、批量注册验证码三类攻击都落在这几条前缀上。
		// 刻意不含 /api/posts、/api/messages、/api/feedback、/api/search 等内容与检索接口，
		// 那些入口被整体封禁会误伤大量正常读写。
		// /api/login_edu 必须显式列出：封禁匹配是完整路由段，
		// /api/login 不会（也不应该）连带命中 /api/login_edu。
		return []string{
			"/api/login", "/api/login_edu", "/api/password",
			"/api/register", "/api/forgot_password", "/api/send_code", "/api/verify_code",
		}, nil
	case securityBlockScopeAll:
		if !input.ConfirmGlobal {
			return nil, errSecurityBlockGlobalUnconfirm
		}
		return []string{""}, nil
	default:
		return nil, errSecurityBlockScopeInvalid
	}
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
	scopes, err := resolveBlockScopes(input)
	if err != nil {
		code := "security_block_scope_invalid"
		switch {
		case errors.Is(err, errSecurityBlockScopeRequired):
			code = "security_block_scope_required"
		case errors.Is(err, errSecurityBlockGlobalUnconfirm):
			code = "security_block_global_confirm_required"
		}
		c.JSON(http.StatusBadRequest, gin.H{"code": code, "error": err.Error()})
		return
	}
	now := time.Now()
	expiresAt := now.Add(time.Duration(input.DurationMin) * time.Minute)
	reason := truncateSecurityNote(input.Reason)
	blocks := make([]models.SecurityBlock, 0, len(scopes))
	// 一个作用域可能对应多条前缀（例如账号安全 = 登录 + 密码链路），
	// 要么全部写入，要么整体不生效，避免留下半个封禁让管理员误判覆盖范围。
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		for _, prefix := range scopes {
			block := models.SecurityBlock{
				ScopeType: "ip_hash", ScopeValue: key, RoutePrefix: prefix,
				Reason: reason, ExpiresAt: expiresAt, CreatedBy: c.GetUint("user_id"), CreatedAt: now,
			}
			if err := tx.Create(&block).Error; err != nil {
				return err
			}
			blocks = append(blocks, block)
		}
		return nil
	}); err != nil {
		h.securityDatabaseError(c)
		return
	}
	ids := make([]uint, 0, len(blocks))
	prefixes := make([]string, 0, len(blocks))
	for _, block := range blocks {
		ids = append(ids, block.ID)
		prefixes = append(prefixes, block.RoutePrefix)
	}
	h.writeSecurityAdminLog(c, "security_block_created", services.MaskSecurityFingerprint(key), reason)
	c.JSON(http.StatusCreated, gin.H{
		"id": blocks[0].ID, "ids": ids, "route_prefixes": prefixes,
		"expires_at": expiresAt,
	})
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
		Actionable:   models.SecurityEventActionable(event.EventType),
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
