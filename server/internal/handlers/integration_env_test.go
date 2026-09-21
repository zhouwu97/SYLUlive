//go:build integration

package handlers

import (
	"os"
	"testing"
)

// requireIntegrationEnv 决定集成测试在缺少环境时是「跳过」还是「直接失败」。
//
// 为什么不能一律 t.Skip：CI 的 postgres-integration job 明确要求这些用例执行，
// 一旦环境注入出了问题（workflow 改错、变量名拼错、数据库名不匹配），
// t.Skip 会让整个 job 变绿——覆盖被静默削弱，而且没人会注意到。
// 因此 CI 里设置 REQUIRE_INTEGRATION_TESTS=1：缺环境必须让测试失败。
// 本地开发不设置该变量，仍然只是跳过，方便只跑单元测试。
func requireIntegrationEnv(t *testing.T, reason string) {
	t.Helper()
	if os.Getenv("REQUIRE_INTEGRATION_TESTS") == "1" {
		t.Fatalf("集成测试必须执行，但环境不满足：%s", reason)
	}
	t.Skip(reason)
}
