package mcpclient

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMinimalMCPEnvDropsMainServiceSecrets(t *testing.T) {
	// Go 服务进程同时装载了这些变量；子进程默认继承会让“独立 MCP 隔离”失效。
	parent := []string{
		"JWT_SECRET=super-secret",
		"DATABASE_DSN=postgres://user:password@host/db",
		"DEEPSEEK_API_KEY=sk-deepseek",
		"SMTP_PASSWORD=mail-secret",
		"RAG_SERVICE_TOKEN=rag-secret",
		"ADMIN_BOOTSTRAP_PASSWORD=admin-secret",
		"HY3_API_KEY=hy3-secret",
		"HY3_MODE=live",
		"PATH=/should/be/replaced",
		"MALFORMED",
	}

	env := minimalMCPEnv(parent)

	require.Contains(t, env, "HY3_API_KEY=hy3-secret")
	require.Contains(t, env, "HY3_MODE=live")
	require.Contains(t, env, "PATH=/usr/local/bin:/usr/bin:/bin")
	require.Contains(t, env, "HOME=/nonexistent")
	for _, leaked := range []string{
		"JWT_SECRET=super-secret",
		"DATABASE_DSN=postgres://user:password@host/db",
		"DEEPSEEK_API_KEY=sk-deepseek",
		"SMTP_PASSWORD=mail-secret",
		"RAG_SERVICE_TOKEN=rag-secret",
		"ADMIN_BOOTSTRAP_PASSWORD=admin-secret",
		"PATH=/should/be/replaced",
		"MALFORMED",
	} {
		require.NotContains(t, env, leaked)
	}
}

func TestLocalCommandAlwaysSetsExplicitEnv(t *testing.T) {
	cmd := localCommand(Config{Command: "/opt/SYLUlive_MCP/bin/run-stdio"})

	// Env 为 nil 时 exec 会继承父进程全部环境，必须显式赋值。
	require.NotNil(t, cmd.Env)
	for _, entry := range cmd.Env {
		require.True(t,
			isAllowedMCPEnvKey(entry[:indexByteOrLen(entry, '=')]) || containsBaseEnv(entry),
			"unexpected inherited env entry: %s", entry,
		)
	}
}

func indexByteOrLen(value string, target byte) int {
	for index := 0; index < len(value); index++ {
		if value[index] == target {
			return index
		}
	}
	return len(value)
}

func containsBaseEnv(entry string) bool {
	for _, base := range mcpBaseEnv {
		if base == entry {
			return true
		}
	}
	return false
}
