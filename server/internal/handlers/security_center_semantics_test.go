package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// 单次密码输错不能进安全中心当「暴力尝试」。
//
// 早期实现让所有登录失败都写 login_bruteforce + medium，安全中心因此被大量
// 「请求 1 次 / 拦截 0 次 / 登录暴力尝试」淹没，管理员看不出哪个账号真的被锁。
func TestLoginFailureOutcomeKeepsSingleFailureOutOfBruteforce(t *testing.T) {
	single := loginFailureOutcome(0)
	if single.EventType != "login_failed" {
		t.Fatalf("未触发锁定的失败应记为 login_failed，实际 %q", single.EventType)
	}
	if single.Severity != models.SecuritySeverityLow || single.Blocked {
		t.Fatalf("单次失败应为低危且未拦截: severity=%q blocked=%v", single.Severity, single.Blocked)
	}
	if single.Action != "observed" {
		t.Fatalf("单次失败应记为 observed，实际 %q", single.Action)
	}

	// 第 3 次失败进入账号锁定：这里才升级为暴力尝试，且必须体现已被处置。
	locked := loginFailureOutcome(time.Minute)
	if locked.EventType != "login_bruteforce" {
		t.Fatalf("达到锁定阈值应升级为 login_bruteforce，实际 %q", locked.EventType)
	}
	if locked.Severity != models.SecuritySeverityMedium || !locked.Blocked {
		t.Fatalf("锁定应记为中危且已拦截: severity=%q blocked=%v", locked.Severity, locked.Blocked)
	}
	if locked.Action != "throttled" {
		t.Fatalf("触发锁定应记为 throttled，实际 %q", locked.Action)
	}

	// 锁定窗口内继续请求：没有比对密码就被拒，属于已拦截。
	if loginLockedOutcome.Action != "blocked" || !loginLockedOutcome.Blocked {
		t.Fatalf("锁定窗口内请求应记为 blocked: %+v", loginLockedOutcome)
	}
}

// 临时封禁默认必须是**最小作用域**：空前缀在服务端等价于「所有高风险接口生效」。
func TestResolveBlockScopesDefaultsToMinimalScope(t *testing.T) {
	scopes, err := resolveBlockScopes(securityBlockInput{RoutePrefix: "/api/login"})
	if err != nil {
		t.Fatalf("仅当前路由应被接受: %v", err)
	}
	if len(scopes) != 1 || scopes[0] != "/api/login" {
		t.Fatalf("默认作用域应只覆盖当前路由，实际 %v", scopes)
	}

	// 旧客户端固定发空 route_prefix 且不带 scope：必须被拒绝，不能隐式升级为全站。
	if _, err := resolveBlockScopes(securityBlockInput{}); err == nil {
		t.Fatal("空作用域必须被拒绝，不能默认全站")
	}
	if _, err := resolveBlockScopes(securityBlockInput{Scope: "route"}); err == nil {
		t.Fatal("route 作用域缺少路由前缀时必须被拒绝")
	}

	accountScopes, err := resolveBlockScopes(securityBlockInput{Scope: securityBlockScopeAccount})
	if err != nil {
		t.Fatalf("账号与验证码链路作用域应被接受: %v", err)
	}
	for _, forbidden := range []string{"/api/posts", "/api/messages", "/api/search", "/api/feedback"} {
		for _, scope := range accountScopes {
			if scope == forbidden {
				t.Fatalf("账号链路作用域不得包含内容/检索接口 %s", forbidden)
			}
		}
	}
	// 教务登录必须显式列出：封禁匹配是完整路由段，/api/login 不会连带命中 /api/login_edu。
	for _, required := range []string{"/api/login", "/api/login_edu", "/api/password"} {
		if !securityScopesContain(accountScopes, required) {
			t.Fatalf("账号链路作用域应包含 %s，实际 %v", required, accountScopes)
		}
	}

	// 全部高风险接口必须显式二次确认。
	if _, err := resolveBlockScopes(securityBlockInput{Scope: securityBlockScopeAll}); err == nil {
		t.Fatal("全站封禁缺少二次确认时必须被拒绝")
	}
	allScopes, err := resolveBlockScopes(securityBlockInput{Scope: securityBlockScopeAll, ConfirmGlobal: true})
	if err != nil {
		t.Fatalf("显式确认后全站封禁应被接受: %v", err)
	}
	if len(allScopes) != 1 || allScopes[0] != "" {
		t.Fatalf("全站封禁应写入空前缀，实际 %v", allScopes)
	}

	// 非敏感路由本来就不查封禁表，接受它只会让管理员误以为封禁生效。
	if _, err := resolveBlockScopes(securityBlockInput{RoutePrefix: "/api/announcements"}); err == nil {
		t.Fatal("非敏感路由不应接受封禁")
	}
	if _, err := resolveBlockScopes(securityBlockInput{Scope: "everything"}); err == nil {
		t.Fatal("未知作用域必须被拒绝")
	}
}

// 首页卡片必须把「待处置」和「审计流水」分开统计。
func TestSecurityOverviewSeparatesActionableFromAudit(t *testing.T) {
	handler, db := newSecurityAdminTestEnv(t)
	now := time.Now()
	seedSecurityEvent(t, db, "audit-blocked", "security_blocked_request", models.SecuritySeverityHigh, now)
	seedSecurityEvent(t, db, "audit-login", "login_failed", models.SecuritySeverityLow, now)
	seedSecurityEvent(t, db, "real-spray", "login_password_spray", models.SecuritySeverityHigh, now)

	recorder := performSecurityAdminGET(t, handler.Overview, "/probe?range=24h")
	if recorder.Code != http.StatusOK {
		t.Fatalf("概览接口失败: %d %s", recorder.Code, recorder.Body.String())
	}
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析概览响应失败: %v", err)
	}
	number := func(key string) int { return int(payload[key].(float64)) }

	// 旧字段把已由封禁层处置掉的高危流水也算成待办，这正是「安全事件 1」被误读的根源。
	if got := number("active_high_count"); got != 2 {
		t.Fatalf("旧口径 active_high_count 应为 2，实际 %d", got)
	}
	if got := number("actionable_high_count"); got != 1 {
		t.Fatalf("高危待处理只应统计待处置事件，期望 1 实际 %d", got)
	}
	if got := number("actionable_pending_count"); got != 1 {
		t.Fatalf("待处置总数期望 1 实际 %d", got)
	}
	if got := number("total_events"); got != 3 {
		t.Fatalf("全部记录应为 3，实际 %d", got)
	}
}

// 默认列表只显示待处置事件，「全部记录」才包含审计流水。
func TestListEventsActionableFilter(t *testing.T) {
	handler, db := newSecurityAdminTestEnv(t)
	now := time.Now()
	seedSecurityEvent(t, db, "audit-reset", "password_reset_activity", models.SecuritySeverityInfo, now)
	seedSecurityEvent(t, db, "real-spray", "password_reset_spray", models.SecuritySeverityHigh, now)

	pending := listSecurityEventIDs(t, handler, "/probe?actionable=true&status=active")
	if len(pending) != 1 {
		t.Fatalf("待处置视图应只返回 1 条，实际 %v", pending)
	}
	audit := listSecurityEventIDs(t, handler, "/probe?actionable=false")
	if len(audit) != 1 {
		t.Fatalf("审计视图应只返回 1 条，实际 %v", audit)
	}
	all := listSecurityEventIDs(t, handler, "/probe")
	if len(all) != 2 {
		t.Fatalf("未指定 actionable 时应返回全部 2 条，实际 %v", all)
	}

	// DTO 需要把判定结果直接告诉客户端，客户端不再自己维护类型清单。
	recorder := performSecurityAdminGET(t, handler.ListEvents, "/probe?actionable=true")
	var payload struct {
		Items []struct {
			EventType  string `json:"event_type"`
			Actionable bool   `json:"actionable"`
		} `json:"items"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析事件列表失败: %v", err)
	}
	if len(payload.Items) != 1 || !payload.Items[0].Actionable {
		t.Fatalf("待处置事件应标记 actionable=true: %+v", payload.Items)
	}
}

// 安全事件采集的运行态必须来自真实写入结果，而不是「表存在」。
//
// 旧实现 `HasTable(&SecurityEvent{}) ? ready : missing` 的致命之处：业务侧统一
// `_ = Record(...)` 忽略错误，写入长期失败时事件整批丢失，后台却一直是绿的。
func TestSecurityOverviewReportsEventCollectionHealth(t *testing.T) {
	handler, security, db := newSecurityAdminTestEnvWithService(t)

	// 表存在但进程内还没发生过写入：报 unknown，不能沿用旧口径直接绿。
	if got := securityProtectionField(t, handler, "security_event_collection"); got != services.SecurityLayerUnknown {
		t.Fatalf("未发生写入时应报 unknown，实际 %q", got)
	}

	input := services.SecurityEventInput{EventType: "login_bruteforce", Severity: models.SecuritySeverityHigh, ClientIP: "1.2.3.4"}
	if err := security.Record(input); err != nil {
		t.Fatalf("写入安全事件失败: %v", err)
	}
	if got := securityProtectionField(t, handler, "security_event_collection"); got != services.SecurityLayerReady {
		t.Fatalf("写入成功后应报 ready，实际 %q", got)
	}

	// 表仍在、写入开始失败：这正是旧口径完全看不见的场景。
	blockSecurityEventInsert(t, db)
	for attempt := 1; attempt <= services.SecurityLayerUnavailableAfterFailures+1; attempt++ {
		if err := security.Record(input); err == nil {
			t.Fatal("触发器应让事件写入失败")
		}
		want := services.SecurityLayerDegraded
		if attempt >= services.SecurityLayerUnavailableAfterFailures {
			want = services.SecurityLayerUnavailable
		}
		if got := securityProtectionField(t, handler, "security_event_collection"); got != want {
			t.Fatalf("第 %d 次连续写入失败后应报 %s，实际 %q", attempt, want, got)
		}
	}
}

// blockSecurityEventInsert 用触发器让 security_events 的写入稳定失败，
// 同时保持表存在——这样才能单独验证「表在但采集坏了」这条路径。
func blockSecurityEventInsert(t *testing.T, db *gorm.DB) {
	t.Helper()
	if err := db.Exec(`CREATE TRIGGER security_events_test_failure BEFORE INSERT ON security_events
		BEGIN SELECT RAISE(ABORT, 'test: event write blocked'); END`).Error; err != nil {
		t.Fatalf("安装事件写入触发器失败: %v", err)
	}
}

func securityProtectionField(t *testing.T, handler *SecurityAdminHandler, key string) string {
	t.Helper()
	value, _ := securityOverviewProtection(t, handler)[key].(string)
	return value
}

func securityProtectionState(t *testing.T, handler *SecurityAdminHandler, key string) map[string]any {
	t.Helper()
	state, _ := securityOverviewProtection(t, handler)[key].(map[string]any)
	if state == nil {
		t.Fatalf("概览缺少 %s", key)
	}
	return state
}

func securityOverviewProtection(t *testing.T, handler *SecurityAdminHandler) map[string]any {
	t.Helper()
	recorder := performSecurityAdminGET(t, handler.Overview, "/probe?range=24h")
	if recorder.Code != http.StatusOK {
		t.Fatalf("概览接口失败: %d %s", recorder.Code, recorder.Body.String())
	}
	var payload struct {
		Protection map[string]any `json:"protection"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析概览响应失败: %v", err)
	}
	return payload.Protection
}

// 来源封禁的开关和运行态必须分开上报。
//
// fail-open 是刻意的设计：附加层故障不该把全站用户误伤。但它有一个副作用——
// 开关 enabled + 表 ready 时封禁层可能正在放行攻击来源，而旧版概览只会显示绿色。
func TestSecurityOverviewBlockStateTracksFailOpen(t *testing.T) {
	handler, security, _ := newSecurityAdminTestEnvWithService(t)

	if state := securityProtectionState(t, handler, "security_block_state"); state["runtime"] != services.SecurityLayerUnknown {
		t.Fatalf("进程启动后还没查询过封禁表时应报 unknown，实际 %v", state["runtime"])
	}

	security.SetSecurityBlockDegraded(true)
	state := securityProtectionState(t, handler, "security_block_state")
	if state["runtime"] != services.SecurityLayerDegraded {
		t.Fatalf("fail-open 期间必须报 degraded，实际 %v", state["runtime"])
	}
	if state["reason"] != "block_lookup_failed_fail_open" {
		t.Fatalf("degraded 需要给出原因，实际 %v", state["reason"])
	}
	// 开关本身仍是配置态，不受运行态影响。
	if flat := securityProtectionField(t, handler, "security_block"); flat != "enabled" {
		t.Fatalf("security_block 应保持配置态语义 enabled，实际 %q", flat)
	}

	security.SetSecurityBlockDegraded(false)
	if state := securityProtectionState(t, handler, "security_block_state"); state["runtime"] != services.SecurityLayerReady {
		t.Fatalf("查询恢复后应回到 ready，实际 %v", state["runtime"])
	}

	handler.SetProtectionConfig(false, handler.trustedProxyCIDRs, "")
	if state := securityProtectionState(t, handler, "security_block_state"); state["runtime"] != services.SecurityLayerNotConfigured || state["configured"] != false {
		t.Fatalf("开关关闭时应报 not_configured 且 configured=false，实际 %v", state)
	}
}

// 验证码额度一行不能再由 handler 凭空写死 "enabled"。
func TestSecurityOverviewReportsVerificationLimitState(t *testing.T) {
	handler, _, db := newSecurityAdminTestEnvWithService(t)

	// 没有接入探测源时如实报 unknown，而不是沿用那个永远为真的字符串。
	if state := securityProtectionState(t, handler, "verification_daily_limit_state"); state["runtime"] != services.SecurityLayerUnknown || state["reason"] != "probe_not_wired" {
		t.Fatalf("未接入探测时应报 unknown/probe_not_wired，实际 %v", state)
	}

	if err := db.AutoMigrate(&models.EmailVerificationRequest{}); err != nil {
		t.Fatalf("迁移验证码请求表失败: %v", err)
	}
	handler.SetVerificationLimitProber(services.NewEmailVerificationService(db, nil, "ip-secret", time.Now))
	state := securityProtectionState(t, handler, "verification_daily_limit_state")
	if state["runtime"] != services.SecurityLayerReady {
		t.Fatalf("额度窗口可读时应报 ready，实际 %v", state["runtime"])
	}
	// 阈值必须来自服务里的真实常量：管理员要能据此判断「6 次/天」到底生效没有。
	detail, _ := state["detail"].(map[string]any)
	if got := detail["target_daily_limit"]; got != float64(6) {
		t.Fatalf("应上报每日额度 6，实际 %v", got)
	}
	if got := securityProtectionField(t, handler, "verification_daily_limit"); got != services.SecurityLayerReady {
		t.Fatalf("扁平字段应与运行态一致，实际 %q", got)
	}

	// 窗口表读不动时限流实际已经失效，这一行必须变色。
	if err := db.Migrator().DropTable(&models.EmailVerificationRequest{}); err != nil {
		t.Fatalf("删除验证码请求表失败: %v", err)
	}
	if state := securityProtectionState(t, handler, "verification_daily_limit_state"); state["runtime"] != services.SecurityLayerUnavailable || state["reason"] != "verification_window_read_failed" {
		t.Fatalf("额度窗口不可读时应报 unavailable，实际 %v", state)
	}
}

func newSecurityAdminTestEnvWithService(t *testing.T) (*SecurityAdminHandler, *services.SecurityEventService, *gorm.DB) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	security := services.NewSecurityEventService(db, "security-test-secret", time.Now)
	handler := NewSecurityAdminHandler(db, security)
	handler.SetProtectionConfig(true, []string{"127.0.0.1/32"}, "")
	return handler, security, db
}

func newSecurityAdminTestEnv(t *testing.T) (*SecurityAdminHandler, *gorm.DB) {
	t.Helper()
	handler, _, db := newSecurityAdminTestEnvWithService(t)
	return handler, db
}

func seedSecurityEvent(t *testing.T, db *gorm.DB, bucketKey, eventType, severity string, now time.Time) {
	t.Helper()
	if err := db.Create(&models.SecurityEvent{
		BucketKey: bucketKey, EventType: eventType, Severity: severity,
		Status: models.SecurityEventStatusActive, Route: "/api/login", Method: "POST",
		SourceIPHash: "source-hash", TargetHash: "target-hash", TargetMasked: "26***27",
		Action: "observed", AttemptCount: 1,
		FirstSeenAt: now, LastSeenAt: now, CreatedAt: now, UpdatedAt: now,
	}).Error; err != nil {
		t.Fatalf("写入安全事件失败: %v", err)
	}
}

func listSecurityEventIDs(t *testing.T, handler *SecurityAdminHandler, target string) []float64 {
	t.Helper()
	recorder := performSecurityAdminGET(t, handler.ListEvents, target)
	if recorder.Code != http.StatusOK {
		t.Fatalf("事件列表接口失败: %d %s", recorder.Code, recorder.Body.String())
	}
	var payload struct {
		Items []struct {
			ID float64 `json:"id"`
		} `json:"items"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("解析事件列表失败: %v", err)
	}
	ids := make([]float64, 0, len(payload.Items))
	for _, item := range payload.Items {
		ids = append(ids, item.ID)
	}
	return ids
}

func performSecurityAdminGET(t *testing.T, handler gin.HandlerFunc, target string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/probe", handler)
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, target, nil))
	return recorder
}

// securityScopesContain 用独立函数名避免与包内已有的 containsString 助手冲突。
func securityScopesContain(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
