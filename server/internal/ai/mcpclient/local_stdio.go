package mcpclient

import (
	"os"
	"os/exec"
	"strings"
)

// mcpEnvPrefixes 是允许透传给 MCP 子进程的环境变量前缀。
// 只有 Hy3 提供方自身的配置需要传入；其余一律不继承。
var mcpEnvPrefixes = []string{"HY3_"}

// mcpBaseEnv 是子进程运行所需的最小环境。
// HOME 指向不存在的路径，避免子进程读写主服务账号的用户目录。
var mcpBaseEnv = []string{
	"PATH=/usr/local/bin:/usr/bin:/bin",
	"LANG=C.UTF-8",
	"LC_ALL=C.UTF-8",
	"HOME=/nonexistent",
}

// localCommand 只启动一个已校验的绝对路径启动包装器，永不解释命令行字符串。
//
// 必须显式设置 Env：exec 默认让子进程继承父进程的全部环境变量，而 Go 服务
// 进程里同时装载了 JWT_SECRET、数据库 DSN、AI_API_KEY、SMTP 口令、
// 推送密钥和 RAG Token。不清空环境时，“独立 MCP 隔离”在 local_stdio 下并不成立。
func localCommand(config Config) *exec.Cmd {
	cmd := exec.Command(config.Command)
	cmd.Env = minimalMCPEnv(os.Environ())
	return cmd
}

// minimalMCPEnv 从父进程环境中只挑出 MCP 自身需要的变量。
func minimalMCPEnv(parentEnv []string) []string {
	env := append([]string(nil), mcpBaseEnv...)
	for _, entry := range parentEnv {
		separator := strings.IndexByte(entry, '=')
		if separator <= 0 {
			continue
		}
		if !isAllowedMCPEnvKey(entry[:separator]) {
			continue
		}
		env = append(env, entry)
	}
	return env
}

func isAllowedMCPEnvKey(key string) bool {
	for _, prefix := range mcpEnvPrefixes {
		if strings.HasPrefix(key, prefix) {
			return true
		}
	}
	return false
}
