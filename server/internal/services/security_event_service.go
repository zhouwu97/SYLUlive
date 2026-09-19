package services

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

// SecurityEventInput 是业务侧允许写入安全中心的白名单字段。
// 不接受任意请求体，避免审计系统成为敏感数据的旁路存储。
type SecurityEventInput struct {
	EventType      string
	Severity       string
	Status         string
	Route          string
	Method         string
	ClientIP       string
	SourceHash     string
	UserAgent      string
	InstallationID string
	ActorUserID    *uint
	TargetType     string
	TargetValue    string
	TargetMasked   string
	RequestID      string
	// SkipAttempt 用于同一请求派生出的邮件投递/结果回调，避免把一次 HTTP 请求重复计入请求数。
	SkipAttempt            bool
	Blocked                bool
	MailSent               bool
	PasswordResetSucceeded bool
	Action                 string
	Metadata               map[string]interface{}
}

// SecurityEventService 负责来源摘要、目标摘要和五分钟聚合写入。
type SecurityEventService struct {
	db     *gorm.DB
	secret []byte
	now    func() time.Time
	// 说明：这里曾经有一个 sync.Mutex 包住事件 UPSERT。它只保护那一句数据库写入，
	// 并不保护其它需要串行的内存状态，却让不同来源的并发事件互相阻塞；
	// 单条原子 UPSERT 本身已由数据库保证正确性，因此该 mutex 已移除。
	attributionValidFrom time.Time
	blockDegraded        atomic.Bool
}

// SetSecurityBlockDegraded 由封禁中间件记录运行时数据库故障，健康检查据此返回 degraded。
func (s *SecurityEventService) SetSecurityBlockDegraded(value bool) {
	if s != nil {
		s.blockDegraded.Store(value)
	}
}

func (s *SecurityEventService) SecurityBlockDegraded() bool {
	return s != nil && s.blockDegraded.Load()
}

func NewSecurityEventService(db *gorm.DB, secret string, now func() time.Time) *SecurityEventService {
	if now == nil {
		now = time.Now
	}
	return &SecurityEventService{db: db, secret: []byte(strings.TrimSpace(secret)), now: now}
}

func (s *SecurityEventService) Hash(value string) string {
	mac := hmac.New(sha256.New, s.secret)
	_, _ = mac.Write([]byte(strings.TrimSpace(value)))
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *SecurityEventService) SourceFingerprint(clientIP string) string {
	return s.Hash(clientIP)
}

func (s *SecurityEventService) SetSourceAttributionValidFrom(raw string) error {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		s.attributionValidFrom = time.Time{}
		return nil
	}
	value, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return err
	}
	s.attributionValidFrom = value
	return nil
}

func MaskSecurityFingerprint(value string) string {
	value = strings.TrimSpace(value)
	if len(value) <= 8 {
		return value
	}
	return value[:4] + "…" + value[len(value)-4:]
}

// securityAuditTimeout 是安全事件写入与封禁查询的等待上限。
// 这些是附加安全层，不能无界地拖住被封禁请求或安全中心的后台操作。
const securityAuditTimeout = 2 * time.Second

// securityEventsTable 是 SecurityEvent 的默认表名（模型未自定义 TableName，
// 连接也未配置 NamingStrategy/TablePrefix）。
//
// 为什么累加表达式必须显式限定目标表：
// PostgreSQL 的 INSERT ... ON CONFLICT (bucket_key) DO UPDATE 会把**目标表和 excluded
// 伪表同时**放进 SET 表达式的名称作用域，于是未限定的 "attempt_count + 1" 会被判定为
// ambiguous 并返回 SQLSTATE 42702（列引用不明确）。SQLite 则会静默按目标表解析。
// 结果是这条缺陷在 SQLite 测试下完全不可见，只在 PostgreSQL 上表现为
// “同一个五分钟桶里第二次及以后的事件永远写不进去”，安全中心计数长期停留在首次值。
const securityEventsTable = "security_events"

// securityEventIncrement 生成“目标表现有值 + delta”的累加表达式，列名限定到目标表，
// 以避开 PostgreSQL ON CONFLICT DO UPDATE 的列引用歧义（见 securityEventsTable 注释）。
func securityEventIncrement(column string, delta int) clause.Expr {
	return gorm.Expr(securityEventsTable+"."+column+" + ?", delta)
}

// Record 写入一条安全观察事件。
//
// 该方法不接收 context，供不掌握请求 context 的后台/异步调用方使用。
// HTTP 请求链路请使用 RecordContext，以便客户端中断时随之取消。
func (s *SecurityEventService) Record(input SecurityEventInput) error {
	return s.RecordContext(context.Background(), input)
}

// RecordContext 在给定 context 下写入安全事件。
//
// 并发语义：事件写入是**单条原子 UPSERT**（bucket_key 上的 ON CONFLICT DO UPDATE），
// 数据库本身保证同桶计数的正确性，因此这里不再用全局 mutex 把无关事件的 I/O 串起来。
// 原有那层 mutex 只保护这一条 UPSERT，没有保护其它必须串行的内存状态；保留它只会让
// 不同来源的并发事件互相阻塞。同桶 attempt/blocked/mail_sent 等计数语义不变，
// 一次请求仍然只计一次；数据库错误继续向上返回，不会被静默伪装成成功。
func (s *SecurityEventService) RecordContext(ctx context.Context, input SecurityEventInput) error {
	if s == nil || s.db == nil {
		return nil
	}
	// 不丢失 HTTP 请求取消，同时给出有限等待预算。
	if ctx == nil {
		ctx = context.Background()
	}
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, securityAuditTimeout)
		defer cancel()
	}
	if strings.TrimSpace(input.EventType) == "" {
		return errors.New("安全事件类型不能为空")
	}
	severity := normalizeSecuritySeverity(input.Severity)
	status := strings.TrimSpace(input.Status)
	if status == "" {
		status = models.SecurityEventStatusActive
	}
	action := strings.TrimSpace(input.Action)
	if action == "" {
		if input.Blocked {
			action = "throttled"
		} else {
			action = "observed"
		}
	}
	now := s.now().UTC()
	bucket := now.Truncate(5 * time.Minute)
	sourceHash := ""
	if strings.TrimSpace(input.SourceHash) != "" {
		sourceHash = strings.TrimSpace(input.SourceHash)
	} else if strings.TrimSpace(input.ClientIP) != "" {
		sourceHash = s.Hash(input.ClientIP)
	}
	targetHash := ""
	if strings.TrimSpace(input.TargetValue) != "" {
		targetHash = s.Hash(input.TargetValue)
	}
	metadataJSON := marshalSecurityMetadata(input.Metadata)
	route := truncateSecurityValue(strings.TrimSpace(input.Route), 160)
	method := truncateSecurityValue(strings.ToUpper(strings.TrimSpace(input.Method)), 12)
	key := fmt.Sprintf("%s|%s|%s|%s|%d", input.EventType, sourceHash, targetHash, route, bucket.Unix())
	sourceUAHash := ""
	if strings.TrimSpace(input.UserAgent) != "" {
		sourceUAHash = s.Hash(input.UserAgent)
	}
	installationHash := ""
	if strings.TrimSpace(input.InstallationID) != "" {
		installationHash = s.Hash(input.InstallationID)
	}
	attributionValid := s.attributionValidFrom.IsZero() || !now.Before(s.attributionValidFrom)
	attemptCount := 1
	if input.SkipAttempt {
		attemptCount = 0
	}
	event := models.SecurityEvent{
		BucketKey: key, EventType: truncateSecurityValue(input.EventType, 64), Severity: severity,
		Status: status, Route: route, Method: method, SourceIPHash: sourceHash,
		SourceAttributionValid: attributionValid,
		SourceUAHash:           sourceUAHash, InstallationHash: installationHash,
		ActorUserID: input.ActorUserID, TargetType: truncateSecurityValue(input.TargetType, 32),
		TargetHash: targetHash, TargetMasked: truncateSecurityValue(input.TargetMasked, 320),
		RequestIDSample: truncateSecurityValue(input.RequestID, 128), AttemptCount: attemptCount,
		BlockedCount: boolInt(input.Blocked), MailSentCount: boolInt(input.MailSent),
		PasswordResetSuccessCount: boolInt(input.PasswordResetSucceeded), Action: action, MetadataJSON: metadataJSON,
		FirstSeenAt: now, LastSeenAt: now, CreatedAt: now, UpdatedAt: now,
	}

	return s.db.WithContext(ctx).Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "bucket_key"}},
		DoUpdates: clause.Assignments(map[string]interface{}{
			"attempt_count":                securityEventIncrement("attempt_count", attemptCount),
			"blocked_count":                securityEventIncrement("blocked_count", boolInt(input.Blocked)),
			"mail_sent_count":              securityEventIncrement("mail_sent_count", boolInt(input.MailSent)),
			"password_reset_success_count": securityEventIncrement("password_reset_success_count", boolInt(input.PasswordResetSucceeded)),
			"last_seen_at":                 now,
			"updated_at":                   now,
			"status":                       status,
			// 同一五分钟聚合桶再次出现新攻击时重新激活事件，旧的处置结果必须清掉，
			// 否则后台会同时显示 active 和历史 resolved_at，造成错误判断。
			"resolved_at":     nil,
			"resolved_by":     nil,
			"resolution_note": "",
		}),
	}).Create(&event).Error
}

// IsBlocked 在默认超时预算内判断来源是否处于临时封禁。
// HTTP 链路请使用 IsBlockedContext。
func (s *SecurityEventService) IsBlocked(clientIP, route string) (bool, error) {
	return s.IsBlockedContext(context.Background(), clientIP, route)
}

// IsBlockedContext 在给定 context 下判断来源是否被临时封禁。
//
// 封禁查询与随后的封禁计数写入都受 context 约束：被封禁请求同步记录事件是既有
// 设计（安全中心需要看到封禁实际挡住了多少请求），但不能因此无界等待。
// 这里的写入属于安全观察事件，失败不会覆盖已完成的正常业务结果。
func (s *SecurityEventService) IsBlockedContext(ctx context.Context, clientIP, route string) (bool, error) {
	if s == nil || s.db == nil || strings.TrimSpace(clientIP) == "" {
		return false, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, securityAuditTimeout)
		defer cancel()
	}
	hash := s.Hash(clientIP)
	var count int64
	err := s.db.WithContext(ctx).Model(&models.SecurityBlock{}).
		Where("scope_type = ? AND scope_value = ? AND expires_at > ? AND revoked_at IS NULL", "ip_hash", hash, s.now()).
		Where("route_prefix = '' OR ? LIKE route_prefix || '%'", route).
		Count(&count).Error
	if err != nil {
		return false, err
	}
	blocked := count > 0
	if blocked {
		// 封禁层本身也要留下聚合计数，否则安全中心只能看到管理员创建了封禁，
		// 看不到封禁实际挡住了多少请求。
		_ = s.RecordContext(ctx, SecurityEventInput{
			EventType: "security_blocked_request", Severity: models.SecuritySeverityHigh,
			Route: route, Method: "BLOCK", ClientIP: clientIP,
			TargetType: "route", TargetValue: route, TargetMasked: route,
			Blocked: true, Action: "blocked",
		})
	}
	return blocked, nil
}

func (s *SecurityEventService) CountDistinctTargets(eventType, clientIP string, since time.Time) (int64, error) {
	if s == nil || s.db == nil {
		return 0, nil
	}
	var count int64
	query := s.db.Model(&models.SecurityEvent{}).Where("event_type = ? AND last_seen_at >= ?", eventType, since)
	if strings.TrimSpace(clientIP) != "" {
		query = query.Where("source_ip_hash = ?", s.Hash(clientIP))
	}
	return count, query.Distinct("target_hash").Count(&count).Error
}

func normalizeSecuritySeverity(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case models.SecuritySeverityInfo, models.SecuritySeverityLow, models.SecuritySeverityMedium, models.SecuritySeverityHigh, models.SecuritySeverityCritical:
		return strings.ToLower(strings.TrimSpace(value))
	default:
		return models.SecuritySeverityMedium
	}
}

func marshalSecurityMetadata(input map[string]interface{}) string {
	if len(input) == 0 {
		return ""
	}
	allowed := map[string]struct{}{
		"purpose": {}, "window": {}, "threshold": {}, "reason": {}, "count": {},
		"distinct_targets": {}, "target_count": {}, "failure_count": {}, "route_group": {},
	}
	filtered := make(map[string]interface{})
	for key, value := range input {
		if _, ok := allowed[key]; ok {
			filtered[key] = value
		}
	}
	if len(filtered) == 0 {
		return ""
	}
	encoded, err := json.Marshal(filtered)
	if err != nil {
		return ""
	}
	return truncateSecurityValue(string(encoded), 2000)
}

func truncateSecurityValue(value string, max int) string {
	value = strings.TrimSpace(value)
	if len(value) <= max {
		return value
	}
	return value[:max]
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

// IsSensitiveSecurityRoute 委托到 middleware.SensitiveSecurityRoute。
//
// services 已经依赖 middleware（见 user_role.go），因此这里是安全的复用方向，
// 不会再产生包循环。保留本函数只为兼容既有调用方；新增代码请直接使用
// middleware.SensitiveSecurityRoute，避免再次出现两份分叉的策略清单。
func IsSensitiveSecurityRoute(path string) bool {
	return middleware.SensitiveSecurityRoute(path)
}

func SecurityHTTPMethod(method string) string {
	if method == "" {
		return http.MethodGet
	}
	return method
}
