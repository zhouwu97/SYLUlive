package middleware

import (
	"os"
	"strings"
)

// SecureCookieEnabled 统一决定会话 Cookie 的 Secure 属性。
// release 模式强制开启，避免部署环境遗漏 SSL/ENV 变量时把 JWT 通过明文连接发送。
func SecureCookieEnabled() bool {
	if strings.EqualFold(strings.TrimSpace(os.Getenv("GIN_MODE")), "release") {
		return true
	}
	return strings.EqualFold(strings.TrimSpace(os.Getenv("COOKIE_SECURE")), "true")
}
