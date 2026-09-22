package services

import (
	"sync"
	"time"
)

// 附加安全层的运行态词汇。旧客户端按 ready 判绿，其余值一律落到告警色，
// 因此这里宁可把「不知道」报出来，也不能在探测失效时继续显示 ready。
const (
	SecurityLayerReady         = "ready"
	SecurityLayerDegraded      = "degraded"
	SecurityLayerUnavailable   = "unavailable"
	SecurityLayerUnknown       = "unknown"
	SecurityLayerNotConfigured = "not_configured"
)

// SecurityLayerUnavailableAfterFailures 是连续失败多少次后认定这一层已经不可用。
// 在此之前只报 degraded：单次抖动不该被读成整层失效。
const SecurityLayerUnavailableAfterFailures = 5

// SecurityHealthLayer 记录一层附加防护的实际成败，用于把「配置了这层防护」
// 与「这层防护此刻真的在工作」分开上报。
//
// 背景：安全中心曾经用 `Migrator().HasTable(...)` 作为「安全事件采集 ready」的依据。
// 表存在只说明 DDL 成功；业务侧写事件一律 `_ = Record(...)` 吞掉错误，于是
// 写入持续失败时攻击照常发生、事件全部丢失，而后台仍然显示绿色 ready。
type SecurityHealthLayer struct {
	mu              sync.RWMutex
	now             func() time.Time
	lastSuccessAt   time.Time
	lastFailureAt   time.Time
	consecutiveFail int
	totalSuccesses  int64
	totalFailures   int64
}

// SecurityHealthSnapshot 是 SecurityHealthLayer 的只读快照。
type SecurityHealthSnapshot struct {
	Attempted           bool
	ConsecutiveFailures int
	TotalSuccesses      int64
	TotalFailures       int64
	LastSuccessAt       time.Time
	LastFailureAt       time.Time
}

func newSecurityHealthLayer(now func() time.Time) *SecurityHealthLayer {
	if now == nil {
		now = time.Now
	}
	return &SecurityHealthLayer{now: now}
}

func (h *SecurityHealthLayer) recordSuccess() {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lastSuccessAt = h.now().UTC()
	h.consecutiveFail = 0
	h.totalSuccesses++
}

func (h *SecurityHealthLayer) recordFailure() {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.lastFailureAt = h.now().UTC()
	h.consecutiveFail++
	h.totalFailures++
}

func (h *SecurityHealthLayer) snapshot() SecurityHealthSnapshot {
	if h == nil {
		return SecurityHealthSnapshot{}
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	return SecurityHealthSnapshot{
		Attempted:           h.totalSuccesses > 0 || h.totalFailures > 0,
		ConsecutiveFailures: h.consecutiveFail,
		TotalSuccesses:      h.totalSuccesses,
		TotalFailures:       h.totalFailures,
		LastSuccessAt:       h.lastSuccessAt,
		LastFailureAt:       h.lastFailureAt,
	}
}

// Status 给出一层防护的运行态结论。
//
// 顺序是刻意安排的：先判最近一次结果是不是失败，再判成功——一次失败在恢复前
// 都不应该被更早的成功掩盖。进程启动后没有任何请求触达这一层时返回 unknown，
// 因为「没出过错」和「没被用过」对管理员是两个完全不同的事实。
func (s SecurityHealthSnapshot) Status() string {
	if !s.Attempted {
		return SecurityLayerUnknown
	}
	if s.ConsecutiveFailures > 0 {
		if s.ConsecutiveFailures >= SecurityLayerUnavailableAfterFailures {
			return SecurityLayerUnavailable
		}
		return SecurityLayerDegraded
	}
	if !s.LastSuccessAt.IsZero() {
		return SecurityLayerReady
	}
	return SecurityLayerUnknown
}

// Detail 导出诊断字段，时间戳只在存在时才带上，避免客户端把零值日期显示出来。
func (s SecurityHealthSnapshot) Detail() map[string]interface{} {
	out := map[string]interface{}{
		"attempted":            s.Attempted,
		"consecutive_failures": s.ConsecutiveFailures,
		"total_successes":      s.TotalSuccesses,
		"total_failures":       s.TotalFailures,
	}
	if !s.LastSuccessAt.IsZero() {
		out["last_success_at"] = s.LastSuccessAt
	}
	if !s.LastFailureAt.IsZero() {
		out["last_failure_at"] = s.LastFailureAt
	}
	return out
}

// SecurityLayerState 是一层防护「配置态」与「运行态」的合并结论。
//
// 这一层判断必须只有一个实现：安全中心总览和 /health 各自推算一遍，就会出现
// A11 描述的那种事实分裂——看板已经降级，探针仍然长期绿色。
type SecurityLayerState struct {
	Configured bool                   `json:"configured"`
	Runtime    string                 `json:"runtime"`
	Reason     string                 `json:"reason,omitempty"`
	Detail     map[string]interface{} `json:"detail,omitempty"`
}

// EventCollectionState 判断安全事件采集的真实运行态。
//
// 早期实现只看 `HasTable(&SecurityEvent{})`：表存在即 ready。但业务侧写事件统一
// `_ = Record(...)` 忽略错误，表在而写入一直失败时，攻击记录会整批丢失且无人察觉。
// 现在以实际 UPSERT 的成败为准；表缺失单独判 unavailable，没有比“写不进去”更严重的降级。
// 启动后一次都没写过是 unknown，不是 ready：「没出过错」和「没被用过」对管理员是两个事实。
func (s *SecurityEventService) EventCollectionState(eventTableReady bool) SecurityLayerState {
	snapshot := s.EventWriteHealth()
	if !eventTableReady {
		return SecurityLayerState{Configured: true, Runtime: SecurityLayerUnavailable, Reason: "security_event_table_missing", Detail: snapshot.Detail()}
	}
	runtime := snapshot.Status()
	reason := ""
	if runtime != SecurityLayerReady {
		reason = "last_write_failed"
		if runtime == SecurityLayerUnknown {
			reason = "not_written_since_start"
		}
	}
	return SecurityLayerState{Configured: true, Runtime: runtime, Reason: reason, Detail: snapshot.Detail()}
}

// BlockLookupState 判断来源封禁查询的真实运行态。
//
// 除累计成败外还读 degraded 标记：/health 过去就是按它判定 fail-open 的，
// 两处必须给出同一结论，否则会出现「/health 说降级、安全中心显示正常」。
func (s *SecurityEventService) BlockLookupState(blockEnabled, blockTableReady bool) SecurityLayerState {
	snapshot := s.BlockCheckHealth()
	if !blockEnabled {
		return SecurityLayerState{Configured: false, Runtime: SecurityLayerNotConfigured, Reason: "block_switch_off", Detail: snapshot.Detail()}
	}
	if !blockTableReady {
		return SecurityLayerState{Configured: true, Runtime: SecurityLayerUnavailable, Reason: "security_block_table_missing", Detail: snapshot.Detail()}
	}
	runtime := snapshot.Status()
	if runtime == SecurityLayerReady && s.SecurityBlockDegraded() {
		runtime = SecurityLayerDegraded
	}
	reason := ""
	switch runtime {
	case SecurityLayerDegraded, SecurityLayerUnavailable:
		reason = "block_lookup_failed_fail_open"
	case SecurityLayerUnknown:
		reason = "not_queried_since_start"
	}
	return SecurityLayerState{Configured: true, Runtime: runtime, Reason: reason, Detail: snapshot.Detail()}
}
