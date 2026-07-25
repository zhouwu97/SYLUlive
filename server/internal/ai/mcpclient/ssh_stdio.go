package mcpclient

import (
	"fmt"
	"net"
	"os/exec"
	"strconv"
)

// sshCommand 仅连接 SSH 受限账户。远端 authorized_keys 应配置强制命令，
// 因此这里不传递远端 Shell 命令，也不允许端口、Agent 或 PTY 转发。
func sshCommand(config Config) *exec.Cmd {
	destination := config.SSHUser + "@" + config.SSHHost
	if net.ParseIP(config.SSHHost) != nil && net.ParseIP(config.SSHHost).To4() == nil {
		destination = fmt.Sprintf("%s@[%s]", config.SSHUser, config.SSHHost)
	}
	arguments := []string{
		"-T",
		"-o", "BatchMode=yes",
		"-o", "IdentitiesOnly=yes",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "UserKnownHostsFile=" + config.SSHKnownHostsPath,
		"-o", "ForwardAgent=no",
		"-o", "ClearAllForwardings=yes",
		"-o", "PermitLocalCommand=no",
		"-o", "RequestTTY=no",
		"-i", config.SSHKeyPath,
		"-p", strconv.Itoa(config.SSHPort),
		destination,
	}
	return exec.Command("ssh", arguments...)
}
