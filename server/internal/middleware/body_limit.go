package middleware

import (
	"errors"
	"mime/multipart"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// BodyLimitRule 为指定请求路径覆盖全局请求体上限。
type BodyLimitRule struct {
	Prefix string
	Limit  int64
}

// RequestBodyLimitMiddleware 在业务中间件和 multipart 解析之前限制请求体。
// 已知 Content-Length 的超大请求会直接返回 413；分块请求则由 MaxBytesReader
// 在读取过程中截断，处理器可用 IsRequestBodyTooLarge 统一识别该错误。
func RequestBodyLimitMiddleware(defaultLimit int64, rules ...BodyLimitRule) gin.HandlerFunc {
	return func(c *gin.Context) {
		limit := defaultLimit
		path := c.Request.URL.Path
		matchedPrefixLength := -1
		for _, rule := range rules {
			prefix := strings.TrimRight(rule.Prefix, "/")
			if rule.Limit > 0 && len(prefix) > matchedPrefixLength && (path == prefix || strings.HasPrefix(path, prefix+"/")) {
				limit = rule.Limit
				matchedPrefixLength = len(prefix)
			}
		}
		if limit <= 0 || c.Request.Body == nil || c.Request.Method == http.MethodGet || c.Request.Method == http.MethodHead {
			c.Next()
			return
		}
		if c.Request.ContentLength > limit {
			c.AbortWithStatusJSON(http.StatusRequestEntityTooLarge, gin.H{
				"code":    "request_body_too_large",
				"message": "请求体超过大小限制",
			})
			return
		}
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, limit)
		c.Next()
	}
}

// IsRequestBodyTooLarge 判断请求体是否被 MaxBytesReader 截断。
func IsRequestBodyTooLarge(err error) bool {
	if err == nil {
		return false
	}
	var maxBytesErr *http.MaxBytesError
	if errors.As(err, &maxBytesErr) || errors.Is(err, multipart.ErrMessageTooLarge) {
		return true
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "request body too large") ||
		strings.Contains(message, "request entity too large") ||
		strings.Contains(message, "multipart: message too large")
}
