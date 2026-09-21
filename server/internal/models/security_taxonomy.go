package models

import (
	"sort"
	"strings"
)

// 安全事件分类（taxonomy）
//
// 安全中心里混着两类完全不同的东西：
//
//  1. 审计流水：正常业务行为或已经由限流/封禁自行处置掉的观察记录。
//     典型是「验证码申请成功」「密码重置成功」「单次密码输错」「验证码冷却」
//     「来源封禁拦截」。它们写入后不需要任何人动手，只用于事后调查。
//  2. 待处置事件：需要管理员判断或升级处置的异常行为。
//     典型是各种喷洒、暴力尝试、可疑改密成功、令牌重放。
//
// 早期实现把两者一起写成 status=active 并全部丢进「处理中」，结果是后台永远
// 处理不完，真正的高危事件被淹没在正常流量里。这里把 actionable 收敛成**唯一**定义点：
// 客户端默认只拉 actionable，审计流水只在「全部记录」里出现。
//
// 判定规则刻意采用「未登记即待处置」：新增事件类型如果忘了登记，宁可让管理员多看到一条，
// 也不能被静默隐藏。只有明确确认属于审计流水的事件类型才登记在下面的白名单里。
var securityAuditEventTypes = map[string]struct{}{
	// 验证码 / 密码重置的正常阶段记录（申请、发信、改密成功）。
	"verification_activity":   {},
	"password_reset_activity": {},
	// 单次或少量密码输错，尚未触发任何锁定。
	"login_failed": {},
	// 验证码冷却拦截：用户点太快，属于自助恢复范围。
	"verification_cooldown": {},
	// 来源封禁已经在中间件层完成处置，这条只是「封禁生效了多少次」的计数流水。
	// 把它计入待处置会让每个被封禁的请求都生成一条待办，封禁越有效后台越吵。
	"security_blocked_request": {},
}

// SecurityEventActionable 判断事件类型是否需要管理员处置。
func SecurityEventActionable(eventType string) bool {
	if _, ok := securityAuditEventTypes[strings.ToLower(strings.TrimSpace(eventType))]; ok {
		return false
	}
	return true
}

// SecurityAuditEventTypes 返回审计流水事件类型清单（已排序，便于拼接稳定 SQL 与测试断言）。
func SecurityAuditEventTypes() []string {
	types := make([]string, 0, len(securityAuditEventTypes))
	for eventType := range securityAuditEventTypes {
		types = append(types, eventType)
	}
	sort.Strings(types)
	return types
}

// 严重等级与处置状态的**单向升级**序数。
//
// 安全事件按 event_type + 来源 + 目标 + 路由 + 5 分钟桶聚合，同一个桶里后来的观察
// 只能把等级抬高，不能把已经升上去的等级降回来：
//
//	07:44 第一次失败  severity=medium action=observed
//	07:45 第三次失败  severity=high   action=blocked
//
// 若两条落在同一个桶，早期实现只累加计数而不同步 severity/action，数据库里会留下
// severity=medium + action=observed，首页按 severity 统计的「高危待处理」因此长期漏报。
// 下面这份序数表是 severity/action 升级的**唯一**顺序来源，SQL 表达式由它生成，
// 避免 Go 侧与 SQL 侧各写一套顺序而分叉。
var securitySeverityRanks = map[string]int{
	SecuritySeverityInfo:     0,
	SecuritySeverityLow:      1,
	SecuritySeverityMedium:   2,
	SecuritySeverityHigh:     3,
	SecuritySeverityCritical: 4,
}

// securityActionRanks 把处置状态映射为「处置强度」序数。
//
// 注意 action 在不同事件类型下的语义并不统一：login_* 用 observed/throttled/blocked，
// 邮件链路用 request_accepted/mail_sent/mail_failed，内容限流用 rate_limited。
// 这里排的是**处置强度**而不是时间先后，目的是保证同一桶里出现更强制处置时状态只升不降：
//   - observed / request_accepted：只是观察到，未做任何处置
//   - mail_sent：投递成功的终态（同一桶里申请 + 发信会落到同一行，发信必须能覆盖申请）
//   - throttled / rate_limited / mail_failed：已产生实际限制或失败
//   - blocked / password_reset_succeeded：已阻断，或已完成的不可逆动作
var securityActionRanks = map[string]int{
	"observed":                 1,
	"request_accepted":         1,
	"mail_sent":                2,
	"throttled":                4,
	"rate_limited":             4,
	"mail_failed":              4,
	"blocked":                  5,
	"password_reset_succeeded": 5,
}

func severityRankOf(value string) int {
	if rank, ok := securitySeverityRanks[strings.ToLower(strings.TrimSpace(value))]; ok {
		return rank
	}
	// 未知等级按最低处理：既不阻止后续升级，也不会因为拼写错误被当成高危。
	return securitySeverityRanks[SecuritySeverityInfo]
}

func actionRankOf(value string) int {
	if rank, ok := securityActionRanks[strings.ToLower(strings.TrimSpace(value))]; ok {
		return rank
	}
	return securityActionRanks["observed"]
}

// SecuritySeverityRank 返回严重等级的升级序数，未知值按 info 处理。
func SecuritySeverityRank(severity string) int {
	return severityRankOf(severity)
}

// SecurityActionRank 返回处置状态的升级序数，未知值按 observed 处理。
func SecurityActionRank(action string) int {
	return actionRankOf(action)
}

// securityRankCaseSQL 由序数表生成 SQL CASE 表达式。
//
// 之所以生成而不是手写：PostgreSQL 的 ON CONFLICT DO UPDATE 需要把列值映射成序数才能
// 表达「只升不降」，手写 CASE 会和 Go 侧的映射表各自漂移。表达式按 key 排序输出，
// 保证同一份配置生成的 SQL 完全一致（可被测试直接断言）。
func securityRankCaseSQL(column string, ranks map[string]int, fallback int) string {
	keys := make([]string, 0, len(ranks))
	for key := range ranks {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	builder.WriteString("CASE lower(")
	builder.WriteString(column)
	builder.WriteString(")")
	for _, key := range keys {
		builder.WriteString(" WHEN '")
		builder.WriteString(key)
		builder.WriteString("' THEN ")
		builder.WriteString(itoaRank(ranks[key]))
	}
	builder.WriteString(" ELSE ")
	builder.WriteString(itoaRank(fallback))
	builder.WriteString(" END")
	return builder.String()
}

// SecuritySeverityRankSQL 返回「列名 -> 严重等级序数」的 SQL CASE 表达式。
func SecuritySeverityRankSQL(column string) string {
	return securityRankCaseSQL(column, securitySeverityRanks, securitySeverityRanks[SecuritySeverityInfo])
}

// SecurityActionRankSQL 返回「列名 -> 处置状态序数」的 SQL CASE 表达式。
func SecurityActionRankSQL(column string) string {
	return securityRankCaseSQL(column, securityActionRanks, securityActionRanks["observed"])
}

// itoaRank 只用于 0~9 的序数，避免为一个数字引入 strconv 的额外分配。
func itoaRank(value int) string {
	if value < 0 {
		value = 0
	}
	if value > 9 {
		value = 9
	}
	return string(rune('0' + value))
}
