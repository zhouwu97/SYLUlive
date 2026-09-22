package handlers

import (
	"context"

	"github.com/gin-gonic/gin"
)

// securityAuditContext 给出 HTTP 链路写安全事件用的 context。
//
// 这里刻意用 WithoutCancel，而不是直接传 c.Request.Context()：客户端中断不应抹掉安全信号。
// 撞库升级、刷新令牌复用、可疑改密成功这几条正是攻击者「断开就查不到」收益最大的记录，
// 让它们跟着浏览器一起消失等于给绕过审计留了开关。
// 等待上限不受此影响——SecurityEventService 写入前仍统一派生内部预算，
// 数据库变慢时辅助安全层不会把业务请求一起拖满。
func securityAuditContext(c *gin.Context) context.Context {
	if c == nil || c.Request == nil {
		return context.Background()
	}
	return context.WithoutCancel(c.Request.Context())
}
