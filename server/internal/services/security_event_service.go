package services

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
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
	// writeFailureMu 保护降级日志的限频窗口。日志只在内存里判间隔，不查库——
	// 数据库正是失败原因，任何「先问一句数据库」的告警设计都会在故障时自我放大。
	writeFailureMu      sync.Mutex
	lastWriteFailureLog time.Time
	// eventWriteHealth 记录事件 UPSERT 的真实成败。业务侧统一 `_ = Record(...)`
	// 吞掉错误，因此这是安全中心唯一能知道「采集其实一直在失败」的地方。
	eventWriteHealth *SecurityHealthLayer
	blockCheckHealth *SecurityHealthLayer
	// alerts 是可选的外部主动告警通道。未接入时安全事件照常采集与入库，
	// 只是没有人被叫醒——安全中心必须如实显示这一点，不能继续报绿。
	alerts *SecurityAlertService
}

// SetAlertService 接入高危事件的外部主动告警；传 nil 表示只采集不外发。
//
// 挂在 RecordContext 成功写入之后：事件进了账本才谈得上叫人，反过来
// 「先发邮件再写库」会让一次数据库故障变成没人能查证的空告警。
func (s *SecurityEventService) SetAlertService(alerts *SecurityAlertService) {
	if s == nil {
		return
	}
	s.alerts = alerts
}

// AlertDeliveryState 报告告警外发的配置态与运行态，供安全中心与运维排查使用。
func (s *SecurityEventService) AlertDeliveryState() (bool, string, string, map[string]interface{}) {
	if s == nil || s.alerts == nil {
		return false, SecurityLayerNotConfigured, "alert_service_not_wired", nil
	}
	return s.alerts.DeliveryState()
}

// notifyAlerts 把刚落账的高危事件交给告警通道。
//
// 只做转发与脱敏映射，不改变事件采集的成功/失败语义：邮件发不出去不能让
// 一次真实攻击的采集结果看起来失败了。
func (s *SecurityEventService) notifyAlerts(event models.SecurityEvent) {
	if s == nil || s.alerts == nil {
		return
	}
	s.alerts.Record(SecurityAlertEvent{
		EventType:    event.EventType,
		Severity:     event.Severity,
		Status:       event.Status,
		Route:        event.Route,
		Method:       event.Method,
		TargetMasked: event.TargetMasked,
		Action:       event.Action,
		RequestID:    event.RequestIDSample,
		OccurredAt:   event.LastSeenAt,
	})
}

// EventWriteHealth 返回安全事件采集的运行态快照。
func (s *SecurityEventService) EventWriteHealth() SecurityHealthSnapshot {
	if s == nil {
		return SecurityHealthSnapshot{}
	}
	return s.eventWriteHealth.snapshot()
}

// BlockCheckHealth 返回来源封禁查询的运行态快照。
func (s *SecurityEventService) BlockCheckHealth() SecurityHealthSnapshot {
	if s == nil {
		return SecurityHealthSnapshot{}
	}
	return s.blockCheckHealth.snapshot()
}

// SetSecurityBlockDegraded 由封禁中间件记录运行时数据库故障，健康检查据此返回 degraded。
// 中间件每次查询都会回报结果，因此该状态是「当前是否仍在故障」，不会在一次抖动后永久锁死。
func (s *SecurityEventService) SetSecurityBlockDegraded(value bool) {
	if s == nil {
		return
	}
	s.blockDegraded.Store(value)
	if value {
		s.blockCheckHealth.recordFailure()
		return
	}
	s.blockCheckHealth.recordSuccess()
}

func (s *SecurityEventService) SecurityBlockDegraded() bool {
	return s != nil && s.blockDegraded.Load()
}

func NewSecurityEventService(db *gorm.DB, secret string, now func() time.Time) *SecurityEventService {
	if now == nil {
		now = time.Now
	}
	return &SecurityEventService{
		db:               db,
		secret:           []byte(strings.TrimSpace(secret)),
		now:              now,
		eventWriteHealth: newSecurityHealthLayer(now),
		blockCheckHealth: newSecurityHealthLayer(now),
	}
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

// SecurityOverviewBudget 是安全中心总览一次请求的总等待上限。
//
// 总览要串行跑十几条聚合统计，套用写入那条 2s 预算会把「一次慢查询」误伤成
// 「整页必然失败」；但也不能像之前那样完全不设限——不携带 context 时，
// 管理员刷新一页慢查询就会一直占着连接。这里给的是整次请求共享的一份预算。
const SecurityOverviewBudget = 5 * time.Second

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

// securityEventMonotonicRank 生成“只在序数升高时才替换”的表达式。
//
// 用途是让同一个五分钟聚合桶里的 severity / action **单向升级**：
//
//	07:44 第一次失败  severity=medium action=observed
//	07:45 第三次失败  severity=high   action=blocked
//
// 两条落在同一个 bucket_key 时，早期实现只累加计数、不同步 severity/action，
// 数据库里留下 severity=medium + action=observed，首页按 severity 统计的
// 「高危待处理」因此长期漏报已拦截的攻击。这里改成只升不降。
//
// 注意 PostgreSQL / SQLite 的 SET 表达式一律对**更新前**的行求值，
// 所以下面 metadata_json 引用 security_events.severity 时读到的是旧等级，语义正确。
// 不能写成 severity = excluded.severity：后面再来一条低等级事件会把 high 冲回 medium。
// 表达式里的序数由 models 的单一顺序表生成（见 models.SecuritySeverityRankSQL）。
func securityEventMonotonicRank(column string, columnRankSQL func(string) string) clause.Expr {
	existing := columnRankSQL(securityEventsTable + "." + column)
	incoming := columnRankSQL("excluded." + column)
	return gorm.Expr("CASE WHEN " + existing + " < " + incoming +
		" THEN excluded." + column + " ELSE " + securityEventsTable + "." + column + " END")
}

// securityEventMetadataUpdate 生成 metadata_json 的覆盖规则：
// 只在「本次带了 metadata」且「本次严重等级不低于现有值」时才覆盖。
//
// 两个条件缺一不可——同等级但空 metadata 的观察（例如封禁计数）不能把之前
// 记录下来的阈值/窗口上下文清掉；低等级观察也不能覆盖高危事件的上下文。
func securityEventMetadataUpdate() clause.Expr {
	incomingSeverity := models.SecuritySeverityRankSQL("excluded.severity")
	existingSeverity := models.SecuritySeverityRankSQL(securityEventsTable + ".severity")
	return gorm.Expr("CASE WHEN excluded.metadata_json <> '' AND " + incomingSeverity + " >= " + existingSeverity +
		" THEN excluded.metadata_json ELSE " + securityEventsTable + ".metadata_json END")
}

// securityEventFillIfEmpty 生成“现有值为空时才用本次值填充”的表达式。
// 用于 method 这类同一桶内不保证每次都有值的描述字段。
func securityEventFillIfEmpty(column string) clause.Expr {
	return gorm.Expr("CASE WHEN " + securityEventsTable + "." + column + " = '' THEN excluded." + column +
		" ELSE " + securityEventsTable + "." + column + " END")
}

// Record 写入一条安全观察事件，使用服务内部的默认预算。
//
// 该方法不接收 context，供确实不掌握调用方 context 的后台/异步路径使用。
// HTTP 链路必须使用 RecordContext：等待上限由本服务统一派生，是否随请求取消则由
// 调用方决定（安全审计侧刻意选择「不随客户端中断取消」，见 handlers.securityAuditContext）。
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
	// 内部预算是**上限**而不是**默认值**：无论父 context 有没有 deadline、给了多长的
	// deadline，都在这里派生一个不晚于预算的截止。只在「父没有 deadline」时补超时的写法
	// 会让带 30s deadline 的调用链原样保留 30s，采集反而成为最慢的一环。
	// WithTimeout 取父子更早者，因此父 deadline 更短时依然按父结束，不会被延长。
	if ctx == nil {
		ctx = context.Background()
	}
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(ctx, securityAuditTimeout)
	defer cancel()
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

	err := s.db.WithContext(ctx).Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "bucket_key"}},
		DoUpdates: clause.Assignments(map[string]interface{}{
			"attempt_count":                securityEventIncrement("attempt_count", attemptCount),
			"blocked_count":                securityEventIncrement("blocked_count", boolInt(input.Blocked)),
			"mail_sent_count":              securityEventIncrement("mail_sent_count", boolInt(input.MailSent)),
			"password_reset_success_count": securityEventIncrement("password_reset_success_count", boolInt(input.PasswordResetSucceeded)),
			"last_seen_at":                 now,
			"updated_at":                   now,
			"status":                       status,
			// severity / action 只能升不能降：同一桶里先 observed 后 blocked 必须落到 blocked，
			// 反过来先 high 后 medium 必须保持 high，否则首页按 severity 统计的高危待处理会漏报。
			"severity":      securityEventMonotonicRank("severity", models.SecuritySeverityRankSQL),
			"action":        securityEventMonotonicRank("action", models.SecurityActionRankSQL),
			"metadata_json": securityEventMetadataUpdate(),
			// method 在同一桶内不保证每次都带值（例如聚合计数写入），只在现有值为空时填充。
			"method": securityEventFillIfEmpty("method"),
			// 同一五分钟聚合桶再次出现新攻击时重新激活事件，旧的处置结果必须清掉，
			// 否则后台会同时显示 active 和历史 resolved_at，造成错误判断。
			"resolved_at":     nil,
			"resolved_by":     nil,
			"resolution_note": "",
		}),
	}).Create(&event).Error
	if err != nil {
		s.eventWriteHealth.recordFailure()
		s.noteEventWriteFailure(err)
		return err
	}
	s.eventWriteHealth.recordSuccess()
	s.notifyAlerts(event)
	return nil
}

// securityEventWriteFailureLogInterval 是同一条采集链路降级日志的最小间隔。
// 事件写入挂在每个被封禁/失败的请求上，没有间隔限制时一次数据库故障会把日志刷爆，
// 真正的告警反而淹没在里面。
const securityEventWriteFailureLogInterval = time.Minute

// noteEventWriteFailure 把「采集正在失败」这条事实推到标准日志，限频且去重。
//
// 这里刻意只走内存判断 + log.Printf：失败已经证明数据库这一侧不可靠，
// 再用同一个写入器记录一次「写入失败」事件（更糟的是它也可能失败并再触发记录）
// 会把一次故障放大成写入风暴。运行态计数由 eventWriteHealth 承担，安全中心与
// /health 读的是同一份。
func (s *SecurityEventService) noteEventWriteFailure(err error) {
	if s == nil {
		return
	}
	now := s.now().UTC()
	s.writeFailureMu.Lock()
	if !s.lastWriteFailureLog.IsZero() && now.Sub(s.lastWriteFailureLog) < securityEventWriteFailureLogInterval {
		s.writeFailureMu.Unlock()
		return
	}
	s.lastWriteFailureLog = now
	s.writeFailureMu.Unlock()
	log.Printf("ERROR security event write failed, 采集已降级（每 %s 最多一条）: %v", securityEventWriteFailureLogInterval, err)
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
	// 同 RecordContext：始终派生 2s 上限，父 deadline 更早时自动以父为准。
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(ctx, securityAuditTimeout)
	defer cancel()
	hash := s.Hash(clientIP)
	var count int64
	err := s.db.WithContext(ctx).Model(&models.SecurityBlock{}).
		Where("scope_type = ? AND scope_value = ? AND expires_at > ? AND revoked_at IS NULL", "ip_hash", hash, s.now()).
		// 路由前缀必须按**完整路由段**匹配，与管理员看到的封禁范围语义一致：
		//   /api/login   命中 /api/login、/api/login/foo
		//   /api/login   不得命中 /api/login_edu、/api/loginfoo
		// 旧的 `? LIKE route_prefix || '%'` 是裸字符串前缀匹配，会让
		// 「仅当前接口 /api/login」的封禁连带封掉教务登录 /api/login_edu。
		Where("route_prefix = '' OR ? = route_prefix OR ? LIKE route_prefix || '/%'", route, route).
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
	return s.CountDistinctTargetsForEvents([]string{eventType}, clientIP, since)
}

// CountDistinctTargetsForEventsContext 在给定 context 下做聚合计数。
//
// 喷洒检测挂在每次登录失败之后，属于「辅助安全判断」：它必须带着请求的取消信号，
// 并且和事件写入共用同一份内部预算，否则数据库变慢时登录接口会陪着一起等满大超时。
func (s *SecurityEventService) CountDistinctTargetsForEventsContext(ctx context.Context, eventTypes []string, clientIP string, since time.Time) (int64, error) {
	if s == nil || s.db == nil {
		return 0, nil
	}
	types := make([]string, 0, len(eventTypes))
	for _, eventType := range eventTypes {
		if trimmed := strings.TrimSpace(eventType); trimmed != "" {
			types = append(types, trimmed)
		}
	}
	if len(types) == 0 {
		return 0, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, securityAuditTimeout)
	defer cancel()
	var count int64
	query := s.db.WithContext(ctx).Model(&models.SecurityEvent{}).
		Where("event_type IN ? AND last_seen_at >= ? AND target_hash <> ''", types, since)
	if strings.TrimSpace(clientIP) != "" {
		query = query.Where("source_ip_hash = ?", s.Hash(clientIP))
	}
	return count, query.Distinct("target_hash").Count(&count).Error
}

// CountDistinctTargetsForEvents 统计同一来源在窗口内针对多少个**不同目标**留下过指定类型的事件。
//
// 不掌握调用方 context 时使用；HTTP 链路请走 CountDistinctTargetsForEventsContext。
//
// 需要跨类型查询的原因：密码喷洒判据是「一个来源扫了很多不同账号」，而账号维度的
// 单次密码输错现在是 login_failed、达到锁定阈值才是 login_bruteforce。只数其中一种
// 会让喷洒检测漏判——这也是把普通失败降级为 login_failed 之后必须同步修的地方。
func (s *SecurityEventService) CountDistinctTargetsForEvents(eventTypes []string, clientIP string, since time.Time) (int64, error) {
	return s.CountDistinctTargetsForEventsContext(context.Background(), eventTypes, clientIP, since)
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
//
// 注意它只回答「这条路径归哪个分组管」。判断一次请求要不要查封禁表请用
// middleware.SensitiveSecurityRouteFor(method, path)——同一路径的 GET 与 POST
// 在内容组里不是一个结论。
func IsSensitiveSecurityRoute(path string) bool {
	return middleware.SensitiveSecurityRoute(path)
}

func SecurityHTTPMethod(method string) string {
	if method == "" {
		return http.MethodGet
	}
	return method
}
