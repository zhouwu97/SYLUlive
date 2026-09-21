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
