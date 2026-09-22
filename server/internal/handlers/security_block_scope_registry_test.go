package handlers

import (
	"context"
	"slices"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

// accountScopePrefixes 解析一次「账号安全」范围，失败即终止测试。
func accountScopePrefixes(t *testing.T) []string {
	t.Helper()
	scopes, err := resolveBlockScopes(securityBlockInput{Scope: securityBlockScopeAccount})
	if err != nil {
		t.Fatalf("解析账号范围失败: %v", err)
	}
	return scopes
}

// SEC-10：管理员选「账号安全」时拿到的路径集合，必须与界面对这个范围的说明、
// 以及中间件实际会查封禁表的路由一致。
//
// 修复前 account 是手抄的 7 条前缀，漏了刷新令牌、改密与邮箱换绑；
// 界面把它讲成「账号相关入口」，管理员以为已经封住改密，实际没有。
func TestAccountScopeCoversEveryCredentialRoute(t *testing.T) {
	scopes := accountScopePrefixes(t)
	mustInclude := []string{
		"/api/login", "/api/login_edu", "/api/register", "/api/forgot_password", "/api/password",
		"/api/send_code", "/api/verify_code",
		"/api/refresh", "/api/auth/refresh",
		"/api/change_password", "/api/user/email",
	}
	for _, prefix := range mustInclude {
		if !slices.Contains(scopes, prefix) {
			t.Fatalf("账号安全范围缺少 %s，实际 %v", prefix, scopes)
		}
	}
	// 范围清单与中间件必须是同一事实：每一条都要真的会被封禁查询命中。
	for _, prefix := range scopes {
		if !middleware.SensitiveSecurityRoute(prefix) {
			t.Fatalf("范围 %s 不在中间件覆盖集合里，写了也不会生效", prefix)
		}
	}
}

// 明确不包含什么：内容与检索入口刻意留在账号范围之外（共享出口误伤面），
// 这一条钉住「补齐到全组」不等于「顺手全站封禁」。
func TestAccountScopeExcludesContentAndSearchRoutes(t *testing.T) {
	scopes := accountScopePrefixes(t)
	for _, prefix := range []string{"/api/posts", "/api/messages", "/api/feedback", "/api/search"} {
		if slices.Contains(scopes, prefix) {
			t.Fatalf("账号安全范围不应包含内容/检索入口 %s", prefix)
		}
	}
}

// 全站范围仍然必须是「空前缀 = 全部敏感路由」，且只有显式确认才能落到这一步。
func TestGlobalScopeStillRequiresExplicitConfirm(t *testing.T) {
	if _, err := resolveBlockScopes(securityBlockInput{Scope: securityBlockScopeAll}); err == nil {
		t.Fatalf("缺少 ConfirmGlobal 时不得解析出全站范围")
	}
	scopes, err := resolveBlockScopes(securityBlockInput{Scope: securityBlockScopeAll, ConfirmGlobal: true})
	if err != nil {
		t.Fatalf("确认后的全站范围应被接受: %v", err)
	}
	if len(scopes) != 1 || scopes[0] != "" {
		t.Fatalf("全站范围应是单条空前缀，实际 %v", scopes)
	}
}

// SEC-11：范围落到数据库后，命中与否必须按完整路由段判断，别名与前缀相似路径不误伤。
func TestAccountScopeBlocksMatchByWholeRouteSegment(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开测试库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	service := services.NewSecurityEventService(db, "test-secret", nil)
	clientIP := "203.0.113.7"
	hash := service.Hash(clientIP)
	now := time.Now().UTC()
	blocks := make([]models.SecurityBlock, 0)
	for _, prefix := range accountScopePrefixes(t) {
		blocks = append(blocks, models.SecurityBlock{
			ScopeType: "ip_hash", ScopeValue: hash, RoutePrefix: prefix,
			Reason: "范围一致性验证", ExpiresAt: now.Add(time.Hour),
			CreatedAt: now,
		})
	}
	if err := db.Create(&blocks).Error; err != nil {
		t.Fatalf("写入封禁记录失败: %v", err)
	}

	cases := []struct {
		route  string
		blocked bool
		why    string
	}{
		{"/api/change_password", true, "改密必须落在账号范围内"},
		{"/api/user/email", true, "邮箱换绑必须落在账号范围内"},
		{"/api/user/email/code", true, "子路径按完整段命中"},
		{"/api/auth/refresh", true, "另一处刷新别名同样在范围内"},
		{"/api/login_edu", true, "教务登录是显式登记的前缀"},
		{"/api/loginfoo", false, "相似前缀不得连带命中"},
		{"/api/posts", false, "内容写入不在账号范围内"},
		{"/api/announcements", false, "普通读取完全不查封禁表"},
	}
	for _, tc := range cases {
		if !tc.blocked && !middleware.SensitiveSecurityRoute(tc.route) {
			// 中间件根本不查这些路径，封禁表自然不该命中；这里直接断语义一致即可。
			continue
		}
		blocked, err := service.IsBlockedContext(context.Background(), clientIP, tc.route)
		if err != nil {
			t.Fatalf("%s 查询失败: %v", tc.route, err)
		}
		if blocked != tc.blocked {
			t.Fatalf("%s 命中结果 %v，期望 %v（%s）", tc.route, blocked, tc.blocked, tc.why)
		}
	}
}
