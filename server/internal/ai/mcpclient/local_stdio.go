package mcpclient

import "os/exec"

// localCommand 只启动一个已校验的绝对路径启动包装器，永不解释命令行字符串。
func localCommand(config Config) *exec.Cmd {
	return exec.Command(config.Command)
}
