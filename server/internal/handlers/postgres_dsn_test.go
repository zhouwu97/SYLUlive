package handlers

import (
	"os"
	"strings"
	"testing"
)

// postgresIntegrationDSN 取出 PostgreSQL 连接串；没有配置时按环境要求跳过或判失败。
//
// 历史坑：本包与 models 里一部分用例只读 TEST_POSTGRES_DSN，而 CI 的
// postgres-integration job 从头到尾注入的是 TEST_DATABASE_DSN，于是这些用例在
// CI 里永远静默跳过——「有真实 PostgreSQL 集成测试」就成了假账（审计 R01 第 8 条：
// 跳过与零匹配不得计为通过）。这里两个变量名都接受（更具体的优先），并且沿用
// REQUIRE_INTEGRATION_TESTS 的判断：CI 里缺环境必须红，本地只是跳。
func postgresIntegrationDSN(t *testing.T, reason string) (string, bool) {
	t.Helper()
	for _, name := range []string{"TEST_POSTGRES_DSN", "TEST_DATABASE_DSN"} {
		if dsn := strings.TrimSpace(os.Getenv(name)); dsn != "" {
			return dsn, true
		}
	}
	if os.Getenv("REQUIRE_INTEGRATION_TESTS") == "1" {
		t.Fatalf("集成测试必须执行，但环境不满足：%s", reason)
		return "", false
	}
	t.Skip(reason)
	return "", false
}
