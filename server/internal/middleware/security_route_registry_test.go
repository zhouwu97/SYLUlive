package middleware

import (
	"strings"
	"testing"
)

// 登记表必须自洽：每条前缀都真的被策略命中，每条前缀都是完整路由段形态，
// 账号范围与「不包含」清单合起来正好是全表——否则界面展示给管理员的范围又变成第二份事实。
func TestSecurityRouteRegistryIsSelfConsistent(t *testing.T) {
	if _, ok := SecurityRouteGroups(SecurityAccountRouteGroups); !ok {
		t.Fatalf("账号范围引用了未登记的分组")
	}
	if _, ok := SecurityRouteGroupByID("no_such_group"); ok {
		t.Fatalf("未知分组必须查不到，不能静默返回空集")
	}

	account, _ := SecurityRoutePrefixes(SecurityAccountRouteGroups)
	content, _ := SecurityRoutePrefixes([]SecurityRouteGroupID{SecurityGroupContentWrite})
	merged := map[string]struct{}{}
	for _, prefix := range append(append([]string{}, account...), content...) {
		merged[prefix] = struct{}{}
	}

	for _, group := range securityRouteGroups {
		if len(group.Prefixes) == 0 {
			t.Fatalf("分组 %s 没有任何路由", group.ID)
		}
		if strings.TrimSpace(group.Purpose) == "" {
			t.Fatalf("分组 %s 缺少用途说明，界面无法向管理员解释封掉了什么", group.ID)
		}
		for _, prefix := range group.Prefixes {
			if !strings.HasPrefix(prefix, "/api/") {
				t.Fatalf("分组 %s 的前缀 %s 不是已注册的 /api 路由", group.ID, prefix)
			}
			if !SensitiveSecurityRoute(prefix) {
				t.Fatalf("前缀 %s 登记了却不被策略命中", prefix)
			}
			if !SensitiveSecurityRoute(prefix + "/child") {
				t.Fatalf("前缀 %s 未覆盖其子路径", prefix)
			}
			if _, covered := merged[prefix]; !covered {
				t.Fatalf("前缀 %s 既不在账号范围也不在排除清单里，界面会漏报", prefix)
			}
		}
	}
	for _, prefix := range account {
		for _, excluded := range content {
			if prefix == excluded {
				t.Fatalf("前缀 %s 同时出现在账号范围与排除清单", prefix)
			}
		}
	}
}

// 完整路由段边界：登记表不能退化成裸字符串前缀匹配。
func TestSecurityRouteMatchingKeepsSegmentBoundary(t *testing.T) {
	lookalikes := map[string]string{
		"/api/loginfoo":    "/api/login",
		"/api/postscript":  "/api/posts",
		"/api/searching":   "/api/search",
		"/api/messagelog":  "/api/messages",
		"/api/feedbackx":   "/api/feedback",
		"/api/user/emailx": "/api/user/email",
	}
	for path, prefix := range lookalikes {
		if SensitiveSecurityRoute(path) {
			t.Fatalf("%s 不应因前缀 %s 被牵连命中", path, prefix)
		}
		if !SensitiveSecurityRoute(prefix) {
			t.Fatalf("登记前缀 %s 本身必须命中", prefix)
		}
	}
}
