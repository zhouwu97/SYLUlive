//go:build integration

package services

import (
	"os"
	"testing"
)

// requireIntegrationEnv 决定集成测试在缺少环境时是「跳过」还是「直接失败」。
//
// 与 handlers 包中的同名辅助保持一致：CI 的 postgres-integration job 设置
// REQUIRE_INTEGRATION_TESTS=1，缺环境必须失败而不是静默跳过，否则用例被排除在
// 覆盖之外也不会有人发现。本地不设置该变量时仍只跳过。
func requireIntegrationEnv(t *testing.T, reason string) {
	t.Helper()
	if os.Getenv("REQUIRE_INTEGRATION_TESTS") == "1" {
		t.Fatalf("集成测试必须执行，但环境不满足：%s", reason)
	}
	t.Skip(reason)
}
