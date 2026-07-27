// Package mcpclient 提供 Go AI Runtime 到独立 MCP 服务的受限 stdio 客户端。
package mcpclient

import (
	"fmt"
	"net"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	TransportLocalStdio = "local_stdio"
	TransportSSHStdio   = "ssh_stdio"

	DefaultToolTimeout = 90 * time.Second
	MaxResultBytes     = 128 << 10
)

var sshUserPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]{0,31}$`)
var sshHostPattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)

// Config 只包含连接独立 MCP 所需的传输参数，不包含 Hy3 API Key。
// 本机模式的 Command 必须指向固定启动包装器；SSH 模式只会连接受限账户的强制命令。
type Config struct {
	Enabled        bool
	Transport      string
	Command        string
	ToolTimeout    time.Duration
	MaxCallsPerRun int

	SSHHost           string
	SSHPort           int
	SSHUser           string
	SSHKeyPath        string
	SSHKnownHostsPath string
}

// Validate 在创建子进程前拒绝可被解释为 Shell 命令、相对路径或不完整 SSH 配置的参数。
func (config Config) Validate() error {
	if !config.Enabled {
		return nil
	}
	if config.ToolTimeout <= 0 {
		return fmt.Errorf("AI_EXTERNAL_MCP_TOOL_TIMEOUT_SECONDS 必须大于 0")
	}
	if config.MaxCallsPerRun != 1 {
		return fmt.Errorf("AI_EXTERNAL_MCP_MAX_CALLS_PER_RUN 当前必须为 1")
	}

	switch config.Transport {
	case TransportLocalStdio:
		if err := validateAbsolutePath("AI_EXTERNAL_MCP_COMMAND", config.Command); err != nil {
			return err
		}
	case TransportSSHStdio:
		if !validSSHHost(config.SSHHost) {
			return fmt.Errorf("AI_EXTERNAL_MCP_SSH_HOST 无效")
		}
		if config.SSHPort < 1 || config.SSHPort > 65535 {
			return fmt.Errorf("AI_EXTERNAL_MCP_SSH_PORT 必须在 1 到 65535 之间")
		}
		if !sshUserPattern.MatchString(strings.TrimSpace(config.SSHUser)) {
			return fmt.Errorf("AI_EXTERNAL_MCP_SSH_USER 无效")
		}
		if err := validateAbsolutePath("AI_EXTERNAL_MCP_SSH_KEY_PATH", config.SSHKeyPath); err != nil {
			return err
		}
		if err := validateAbsolutePath("AI_EXTERNAL_MCP_KNOWN_HOSTS_PATH", config.SSHKnownHostsPath); err != nil {
			return err
		}
	default:
		return fmt.Errorf("AI_EXTERNAL_MCP_TRANSPORT 只能是 %s 或 %s", TransportLocalStdio, TransportSSHStdio)
	}
	return nil
}

func validateAbsolutePath(name, value string) error {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "\x00\r\n") || !filepath.IsAbs(value) {
		return fmt.Errorf("%s 必须是绝对路径", name)
	}
	return nil
}

func validSSHHost(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "@/\\\x00\r\n") {
		return false
	}
	if net.ParseIP(value) != nil {
		return true
	}
	// IPv6 使用裸地址传入，由 sshCommand 负责补充方括号；主机名不能包含冒号。
	if strings.Contains(value, ":") {
		return false
	}
	return sshHostPattern.MatchString(value) && !strings.Contains(value, "..")
}
