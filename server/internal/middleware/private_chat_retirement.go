package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// PrivateChatDisabledCode 是私聊整体下线时返回给客户端的稳定错误码，
// 客户端据此判定"功能被管理员暂停"而不是网络或权限异常。
const PrivateChatDisabledCode = "PRIVATE_CHAT_DISABLED"

// PrivateChatRetirementGate 在认证、请求体解析和幂等读取之前短路整个私聊接口组。
//
// 关闭私聊期间 HTTP 层不再接受任何私聊流量，覆盖：
//   - REST 读写（会话列表、拉取消息、发送、已读、未读数）
//   - SSE 实时通道 /api/messages/events
//   - 私信附件下载 /api/messages/files/:file_id
//
// 这里只读取开关和 URL 路径，不查数据库、不读取请求体，因此旧客户端即使仍在
// 轮询也不会产生鉴权查询、不会建立幂等记录，也不会把消息内容送进后端链路。
func PrivateChatRetirementGate(disabled bool) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !disabled {
			c.Next()
			return
		}
		if !isPrivateChatPath(c.Request.URL.Path) {
			c.Next()
			return
		}
		c.AbortWithStatusJSON(http.StatusGone, gin.H{
			"code":  PrivateChatDisabledCode,
			"error": "私聊功能已暂停开放",
		})
	}
}

// isPrivateChatPath 判断路径是否属于私聊接口组 /api/messages。
// 通过 TrimRight 归一化尾斜杠，避免 /api/messages/ 之类的等价路径绕过闸门。
func isPrivateChatPath(path string) bool {
	trimmed := strings.TrimRight(path, "/")
	return trimmed == "/api/messages" || strings.HasPrefix(trimmed, "/api/messages/")
}
