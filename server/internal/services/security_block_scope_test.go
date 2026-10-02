package services

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

// 封禁的路由前缀必须按**完整路由段**匹配，与管理员在封禁对话框里看到的范围一致。
// 旧的裸字符串前缀匹配会让「仅当前接口 /api/login」连带封掉 /api/login_edu
// （教务登录）甚至 /api/loginfoo，造成共享出口上的大批用户被误伤。
func TestSecurityBlockMatchesWholeRouteSegmentsOnly(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	service := NewSecurityEventService(db, "security-test-secret", time.Now)
	scopeValue := service.Hash("203.0.113.50")
	if err := db.Create(&models.SecurityBlock{
		ScopeType:   "ip_hash",
		ScopeValue:  scopeValue,
		RoutePrefix: "/api/login",
		ExpiresAt:   time.Now().Add(time.Hour),
		CreatedAt:   time.Now(),
	}).Error; err != nil {
		t.Fatalf("写入封禁失败: %v", err)
	}

	cases := []struct {
		route   string
		blocked bool
	}{
		{"/api/login", true},
		{"/api/login/foo", true},
		{"/api/login_edu", false},
		{"/api/loginfoo", false},
		{"/api/posts", false},
	}
	for _, tc := range cases {
		blocked, err := service.IsBlocked("203.0.113.50", tc.route)
		if err != nil {
			t.Fatalf("查询封禁状态失败 (%s): %v", tc.route, err)
		}
		if blocked != tc.blocked {
			t.Fatalf("route=%s blocked=%v, want %v", tc.route, blocked, tc.blocked)
		}
	}

	// 其它来源不受影响。
	if blocked, err := service.IsBlocked("198.51.100.1", "/api/login"); err != nil || blocked {
		t.Fatalf("其它来源不应被封禁: blocked=%v err=%v", blocked, err)
	}
}

// 空前缀只表示**显式**创建的全局封禁，覆盖所有路由。
func TestSecurityBlockEmptyPrefixIsExplicitGlobal(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	service := NewSecurityEventService(db, "security-test-secret", time.Now)
	if err := db.Create(&models.SecurityBlock{
		ScopeType:   "ip_hash",
		ScopeValue:  service.Hash("203.0.113.51"),
		RoutePrefix: "",
		ExpiresAt:   time.Now().Add(time.Hour),
		CreatedAt:   time.Now(),
	}).Error; err != nil {
		t.Fatalf("写入全局封禁失败: %v", err)
	}

	for _, route := range []string{"/api/login", "/api/login_edu", "/api/posts", "/api/password/email/code"} {
		blocked, err := service.IsBlocked("203.0.113.51", route)
		if err != nil {
			t.Fatalf("查询全局封禁失败 (%s): %v", route, err)
		}
		if !blocked {
			t.Fatalf("显式全局封禁应覆盖 %s", route)
		}
	}
}

// SEC-TZ：封禁过期判断必须在任意部署时区下正确。存档写入的是 UTC 时间，
// 查询比较值曾经直接使用本地时区的 now（如 Asia/Shanghai +8），字符串化的
// 本地时间与 UTC 存档比较会让未过期封禁被误判为已过期、已过期封禁继续命中。
// 这里显式把进程时区钉在非 UTC 区域，钉住「比较值必须与存档同为 UTC」。
func TestSecurityBlockExpiryIndependentOfLocalTimezone(t *testing.T) {
	originalLocal := time.Local
	time.Local = time.FixedZone("Asia/Shanghai", 8*60*60)
	t.Cleanup(func() { time.Local = originalLocal })

	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.SecurityEvent{}, &models.SecurityBlock{}); err != nil {
		t.Fatalf("迁移安全表失败: %v", err)
	}
	// now 返回本地时区时间，模拟未收敛到 UTC 的调用方；currentTime() 必须兜底。
	localNow := func() time.Time { return time.Now() }
	service := NewSecurityEventService(db, "security-test-secret", localNow)
	scopeValue := service.Hash("203.0.113.60")

	now := time.Now().UTC()
	blocks := []models.SecurityBlock{
		{ScopeType: "ip_hash", ScopeValue: scopeValue, RoutePrefix: "/api/change_password",
			Reason: "未过期", ExpiresAt: now.Add(time.Hour), CreatedAt: now},
		{ScopeType: "ip_hash", ScopeValue: scopeValue, RoutePrefix: "/api/user/email",
			Reason: "已过期", ExpiresAt: now.Add(-time.Minute), CreatedAt: now},
		{ScopeType: "ip_hash", ScopeValue: scopeValue, RoutePrefix: "/api/auth/refresh",
			Reason: "已撤销", ExpiresAt: now.Add(time.Hour), CreatedAt: now,
			RevokedAt: &now},
	}
	if err := db.Create(&blocks).Error; err != nil {
		t.Fatalf("写入封禁失败: %v", err)
	}

	cases := []struct {
		route   string
		blocked bool
		why     string
	}{
		{"/api/change_password", true, "尚未过期的封禁仍须命中"},
		{"/api/user/email", false, "已过期的封禁不得命中"},
		{"/api/auth/refresh", false, "已撤销的封禁不得命中"},
		{"/api/user/email/code", false, "已过期封禁的子路径同样不命中"},
		{"/api/change_password/extra", true, "子路径按完整段命中"},
		{"/api/change_passwordx", false, "相似前缀不得连带命中"},
		{"/api/posts", false, "非敏感路由不在本用例封禁范围内"},
	}
	for _, tc := range cases {
		blocked, err := service.IsBlocked("203.0.113.60", tc.route)
		if err != nil {
			t.Fatalf("查询封禁状态失败 (%s): %v", tc.route, err)
		}
		if blocked != tc.blocked {
			t.Fatalf("route=%s blocked=%v, want %v（%s）", tc.route, blocked, tc.blocked, tc.why)
		}
	}
}
