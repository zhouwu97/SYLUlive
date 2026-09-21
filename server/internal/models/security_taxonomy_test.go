package models

import (
	"strings"
	"testing"
)

// 审计流水与待处置事件的边界必须是**明确**的：
// 正常验证码、正常改密、单次密码输错、冷却拦截、已生效的来源封禁计数都不需要管理员动手。
// 如果它们被算进待处置，安全中心会永远处理不完，真正的高危事件被淹没。
func TestSecurityEventActionableClassification(t *testing.T) {
	auditTypes := []string{
		"verification_activity",
		"password_reset_activity",
		"login_failed",
		"verification_cooldown",
		"security_blocked_request",
	}
	for _, eventType := range auditTypes {
		if SecurityEventActionable(eventType) {
			t.Fatalf("%s 属于审计流水，不应进入待处置", eventType)
		}
	}

	actionableTypes := []string{
		"login_password_spray",
		"login_bruteforce",
		"password_reset_spray",
		"verification_spray",
		"email_target_flood",
		"verification_code_bruteforce",
		"suspicious_password_reset_succeeded",
		"refresh_token_reused",
		"content_post_flood",
		// 未登记的新类型必须默认可见：宁可多显示，不能把新增攻击类型静默隐藏。
		"some_future_event_type",
	}
	for _, eventType := range actionableTypes {
		if !SecurityEventActionable(eventType) {
			t.Fatalf("%s 应属于待处置事件", eventType)
		}
	}

	// 大小写与空白不应影响判定。
	if SecurityEventActionable("  LOGIN_FAILED  ") {
		t.Fatal("判定应忽略大小写与首尾空白")
	}
}

func TestSecuritySeverityRankIsStrictlyIncreasing(t *testing.T) {
	order := []string{
		SecuritySeverityInfo,
		SecuritySeverityLow,
		SecuritySeverityMedium,
		SecuritySeverityHigh,
		SecuritySeverityCritical,
	}
	for i := 1; i < len(order); i++ {
		if SecuritySeverityRank(order[i]) <= SecuritySeverityRank(order[i-1]) {
			t.Fatalf("严重等级序数必须严格递增: %s <= %s", order[i], order[i-1])
		}
	}
	if SecuritySeverityRank("nonsense") != SecuritySeverityRank(SecuritySeverityInfo) {
		t.Fatal("未知等级应按 info 处理，既不能阻止升级也不算高危")
	}
}

func TestSecurityActionRankReflectsDispositionStrength(t *testing.T) {
	if !(SecurityActionRank("observed") < SecurityActionRank("mail_sent")) {
		t.Fatal("投递成功是比单纯观察更强的阶段，应能覆盖申请")
	}
	if !(SecurityActionRank("mail_sent") < SecurityActionRank("throttled")) {
		t.Fatal("已限流必须能覆盖投递阶段")
	}
	if !(SecurityActionRank("throttled") <= SecurityActionRank("blocked")) {
		t.Fatal("已拦截不得低于已限流")
	}
	if SecurityActionRank("unknown-action") != SecurityActionRank("observed") {
		t.Fatal("未知 action 应按最低处置强度处理")
	}
}

// SQL 表达式必须与 Go 侧序数表保持一致，否则「只升不降」在数据库层会退化成另一套顺序。
func TestSecurityRankSQLMatchesGoRanks(t *testing.T) {
	severities := []string{
		SecuritySeverityInfo,
		SecuritySeverityLow,
		SecuritySeverityMedium,
		SecuritySeverityHigh,
		SecuritySeverityCritical,
	}
	assertRankSQL(t, SecuritySeverityRankSQL("security_events.severity"), severities, SecuritySeverityRank)

	actions := []string{
		"observed", "request_accepted", "mail_sent",
		"throttled", "rate_limited", "mail_failed", "blocked", "password_reset_succeeded",
	}
	assertRankSQL(t, SecurityActionRankSQL("excluded.action"), actions, SecurityActionRank)
}

func assertRankSQL(t *testing.T, sql string, values []string, rankOf func(string) int) {
	t.Helper()
	if !strings.HasPrefix(sql, "CASE lower(") || !strings.HasSuffix(sql, " END") {
		t.Fatalf("序数表达式结构异常: %s", sql)
	}
	for _, value := range values {
		marker := "WHEN '" + value + "' THEN "
		index := strings.Index(sql, marker)
		if index < 0 {
			t.Fatalf("序数表达式缺少 %q 分支: %s", value, sql)
		}
		got := int(sql[index+len(marker)] - '0')
		if want := rankOf(value); got != want {
			t.Fatalf("%s 在 SQL 中的序数 %d 与 Go 侧 %d 不一致", value, got, want)
		}
	}
}
