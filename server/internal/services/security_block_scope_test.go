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
