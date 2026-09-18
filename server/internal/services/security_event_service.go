package services

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

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
	db                   *gorm.DB
	secret               []byte
	now                  func() time.Time
	mu                   sync.Mutex
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

func (s *SecurityEventService) Record(input SecurityEventInput) error {
	if s == nil || s.db == nil {
		return nil
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

	s.mu.Lock()
	defer s.mu.Unlock()
	return s.db.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "bucket_key"}},
		DoUpdates: clause.Assignments(map[string]interface{}{
			"attempt_count":                gorm.Expr("attempt_count + ?", attemptCount),
			"blocked_count":                gorm.Expr("blocked_count + ?", boolInt(input.Blocked)),
			"mail_sent_count":              gorm.Expr("mail_sent_count + ?", boolInt(input.MailSent)),
			"password_reset_success_count": gorm.Expr("password_reset_success_count + ?", boolInt(input.PasswordResetSucceeded)),
			"last_seen_at":                 now,
			"updated_at":                   now,
			"status":                       status,
		}),
	}).Create(&event).Error
}

func (s *SecurityEventService) IsBlocked(clientIP, route string) (bool, error) {
	if s == nil || s.db == nil || strings.TrimSpace(clientIP) == "" {
		return false, nil
	}
	hash := s.Hash(clientIP)
	var count int64
	err := s.db.Model(&models.SecurityBlock{}).
		Where("scope_type = ? AND scope_value = ? AND expires_at > ? AND revoked_at IS NULL", "ip_hash", hash, s.now()).
		Where("route_prefix = '' OR ? LIKE route_prefix || '%'", route).
		Count(&count).Error
	blocked := count > 0
	if blocked {
		// 封禁层本身也要留下聚合计数，否则安全中心只能看到管理员创建了封禁，
		// 看不到封禁实际挡住了多少请求。
		_ = s.Record(SecurityEventInput{
			EventType: "security_blocked_request", Severity: models.SecuritySeverityHigh,
			Route: route, Method: "BLOCK", ClientIP: clientIP,
			TargetType: "route", TargetValue: route, TargetMasked: route,
			Blocked: true, Action: "blocked",
		})
	}
	return blocked, err
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

func IsSensitiveSecurityRoute(path string) bool {
	return strings.HasPrefix(path, "/api/login") ||
		strings.HasPrefix(path, "/api/password/") ||
		strings.HasPrefix(path, "/api/register") ||
		strings.HasPrefix(path, "/api/forgot_password") ||
		strings.HasPrefix(path, "/api/refresh") ||
		strings.HasPrefix(path, "/api/auth/refresh") ||
		strings.HasPrefix(path, "/api/change_password") ||
		strings.HasPrefix(path, "/api/user/email") ||
		strings.HasPrefix(path, "/api/send_code") ||
		strings.HasPrefix(path, "/api/verify_code") ||
		strings.HasPrefix(path, "/api/search") ||
		strings.HasPrefix(path, "/api/posts") ||
		strings.HasPrefix(path, "/api/messages") ||
		strings.HasPrefix(path, "/api/feedback")
}

func SecurityHTTPMethod(method string) string {
	if method == "" {
		return http.MethodGet
	}
	return method
}
