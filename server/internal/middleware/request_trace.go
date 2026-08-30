package middleware

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type requestIDContextKey struct{}

const requestIDGinKey = "request_id"
const maxCapturedResponseBytes = 1 << 20

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$`)

// NewRequestID 生成可跨服务传递的请求链路 ID。
func NewRequestID() string {
	return uuid.NewString()
}

// RequestIDFromContext 从 Go 内部调用上下文读取请求链路 ID。
func RequestIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	requestID, _ := ctx.Value(requestIDContextKey{}).(string)
	return requestID
}

// DetachedRequestContext 创建不受原请求取消影响的后台上下文，并保留请求链路 ID。
func DetachedRequestContext(ctx context.Context) context.Context {
	requestID := RequestIDFromContext(ctx)
	if requestID == "" {
		requestID = NewRequestID()
	}
	return context.WithValue(context.Background(), requestIDContextKey{}, requestID)
}

// RequestID 返回 Gin 请求当前使用的请求链路 ID。
func RequestID(c *gin.Context) string {
	if c == nil {
		return ""
	}
	return c.GetString(requestIDGinKey)
}

// EnsureRequestID 为未经过全局中间件的测试路由和边缘 handler 补齐请求 ID。
func EnsureRequestID(c *gin.Context) string {
	if requestID := RequestID(c); requestID != "" {
		return requestID
	}

	requestID := normalizeRequestID(c.GetHeader("X-Request-ID"))
	if requestID == "" {
		requestID = NewRequestID()
	}
	setRequestID(c, requestID)
	return requestID
}

// WriteAPIError 写入统一 API 错误格式。业务 code 必须稳定，message 仅用于展示。
func WriteAPIError(c *gin.Context, status int, code, message string, details gin.H) {
	requestID := EnsureRequestID(c)
	c.Set("error_code", code)
	c.Header("X-Request-ID", requestID)
	payload := gin.H{
		"code":       code,
		"message":    message,
		"request_id": requestID,
	}
	if len(details) > 0 {
		payload["details"] = details
	}
	c.JSON(status, payload)
}

// RequestTraceMiddleware 负责请求 ID、错误响应标准化和无敏感字段结构化访问日志。
// 日志只记录请求链路、路由、方法、状态、耗时、用户 ID、错误码和依赖名，
// 不记录 Authorization、JWT、密码、验证码或完整业务 payload。
func RequestTraceMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		requestID := normalizeRequestID(c.GetHeader("X-Request-ID"))
		if requestID == "" {
			requestID = NewRequestID()
		}
		setRequestID(c, requestID)
		c.Header("X-Request-ID", requestID)

		startedAt := time.Now()
		originalWriter := c.Writer
		if !strings.HasPrefix(c.Request.URL.Path, "/api/") {
			c.Next()
			logRequest(c, requestID, c.Writer.Status(), time.Since(startedAt), c.GetString("error_code"))
			return
		}
		captureWriter := &responseCaptureWriter{ResponseWriter: originalWriter}
		c.Writer = captureWriter

		c.Next()

		status := captureWriter.Status()
		body := captureWriter.body.Bytes()
		errorCode := c.GetString("error_code")
		if !captureWriter.passthrough && isAPIError(c, status) {
			body, errorCode = normalizeAPIError(status, body, requestID)
			c.Set("error_code", errorCode)
		}

		c.Writer = originalWriter
		if captureWriter.Written() {
			captureWriter.forward(body)
			logRequest(c, requestID, status, time.Since(startedAt), errorCode)
			return
		}
		// gin 路由级 404/405 不经过任何 handler，状态由 gin 直接写在底层
		// writer 上。此时兜底 forward 会把未知路径提交成 200 空响应，客户端
		// 会把打错的路径当成成功；交还 gin 完成默认错误响应。
		logRequest(c, requestID, originalWriter.Status(), time.Since(startedAt), errorCode)
	}
}

func setRequestID(c *gin.Context, requestID string) {
	c.Set(requestIDGinKey, requestID)
	if c.Request != nil {
		c.Request = c.Request.WithContext(
			context.WithValue(c.Request.Context(), requestIDContextKey{}, requestID),
		)
	}
}

func normalizeRequestID(value string) string {
	value = strings.TrimSpace(value)
	if !requestIDPattern.MatchString(value) {
		return ""
	}
	return value
}

func isAPIError(c *gin.Context, status int) bool {
	return status >= http.StatusBadRequest &&
		strings.HasPrefix(c.Request.URL.Path, "/api/") &&
		!strings.Contains(strings.ToLower(c.Writer.Header().Get("Content-Type")), "text/event-stream")
}

func normalizeAPIError(status int, body []byte, requestID string) ([]byte, string) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		raw = nil
	}

	code := rawString(raw, "code")
	if code == "" {
		code = rawString(raw, "error_code")
	}
	if code == "" {
		code = httpStatusErrorCode(status)
	}

	message := rawString(raw, "message")
	if message == "" {
		message = rawString(raw, "error")
	}
	if message == "" {
		if detail, ok := raw["detail"]; ok {
			message = rawStringValue(detail)
		}
	}
	if message == "" {
		message = httpStatusErrorMessage(status)
	}

	payload := gin.H{
		"code":       code,
		"message":    message,
		"request_id": requestID,
	}
	if details := collectErrorDetails(raw); len(details) > 0 {
		payload["details"] = details
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return []byte(`{"code":"internal_error","message":"服务器暂不可用"}`), "internal_error"
	}
	return encoded, code
}

func rawString(raw map[string]json.RawMessage, key string) string {
	if raw == nil {
		return ""
	}
	value, ok := raw[key]
	if !ok {
		return ""
	}
	return rawStringValue(value)
}

func rawStringValue(value json.RawMessage) string {
	var text string
	if json.Unmarshal(value, &text) == nil {
		return strings.TrimSpace(text)
	}
	return ""
}

func collectErrorDetails(raw map[string]json.RawMessage) gin.H {
	if raw == nil {
		return nil
	}
	details := gin.H{}
	if value, ok := raw["details"]; ok {
		var nested map[string]interface{}
		if json.Unmarshal(value, &nested) == nil {
			for key, item := range nested {
				details[key] = item
			}
		}
	}
	if value, ok := raw["detail"]; ok {
		var nested map[string]interface{}
		if json.Unmarshal(value, &nested) == nil {
			for key, item := range nested {
				details[key] = item
			}
		}
	}
	for key, value := range raw {
		switch key {
		case "code", "error_code", "message", "error", "detail", "details", "request_id":
			continue
		}
		var decoded interface{}
		if json.Unmarshal(value, &decoded) == nil {
			details[key] = decoded
		}
	}
	return details
}

func httpStatusErrorCode(status int) string {
	switch status {
	case http.StatusBadRequest:
		return "bad_request"
	case http.StatusUnauthorized:
		return "authentication_required"
	case http.StatusForbidden:
		return "forbidden"
	case http.StatusNotFound:
		return "not_found"
	case http.StatusConflict:
		return "conflict"
	case http.StatusTooManyRequests:
		return "rate_limited"
	default:
		if status >= 500 {
			return "internal_error"
		}
		return "request_failed"
	}
}

func httpStatusErrorMessage(status int) string {
	if status >= 500 {
		return "服务器暂不可用"
	}
	return "请求处理失败"
}

func logRequest(c *gin.Context, requestID string, status int, latency time.Duration, errorCode string) {
	route := c.FullPath()
	if route == "" {
		route = c.Request.URL.Path
	}
	userID := ""
	if value, ok := c.Get("user_id"); ok {
		userID = strings.TrimSpace(toString(value))
	}
	slog.Default().Info("http_request",
		"request_id", requestID,
		"route", route,
		"method", c.Request.Method,
		"status", status,
		"latency_ms", latency.Milliseconds(),
		"user_id", userID,
		"error_code", errorCode,
		"dependency", c.GetString("dependency"),
	)
}

func toString(value interface{}) string {
	switch typed := value.(type) {
	case string:
		return typed
	case uint:
		return fmtUint(typed)
	case uint64:
		return fmtUint64(typed)
	case int:
		return fmtInt(typed)
	default:
		return ""
	}
}

// 小型格式化函数避免把用户数据交给通用 fmt 或日志序列化器。
func fmtUint(value uint) string     { return fmtUint64(uint64(value)) }
func fmtUint64(value uint64) string { return strconv.FormatUint(value, 10) }
func fmtInt(value int) string       { return strconv.Itoa(value) }

type responseCaptureWriter struct {
	gin.ResponseWriter
	body        bytes.Buffer
	status      int
	wroteHeader bool
	passthrough bool
}

func (w *responseCaptureWriter) WriteHeader(code int) {
	// Gin 使用负数状态码作为渲染控制信号，不能将其写入真实响应。
	if code <= 0 {
		return
	}
	if w.passthrough {
		w.ResponseWriter.WriteHeader(code)
		return
	}
	if w.wroteHeader {
		return
	}
	w.status = code
	w.wroteHeader = true
}

func (w *responseCaptureWriter) Write(data []byte) (int, error) {
	w.WriteHeaderNow()
	if w.passthrough {
		return w.ResponseWriter.Write(data)
	}
	if w.body.Len()+len(data) > maxCapturedResponseBytes {
		w.passthrough = true
		w.forward(w.body.Bytes())
		w.body.Reset()
		return w.ResponseWriter.Write(data)
	}
	return w.body.Write(data)
}

func (w *responseCaptureWriter) WriteString(value string) (int, error) {
	return w.Write([]byte(value))
}

func (w *responseCaptureWriter) WriteHeaderNow() {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
}

func (w *responseCaptureWriter) Status() int {
	if w.status == 0 {
		return http.StatusOK
	}
	return w.status
}

func (w *responseCaptureWriter) Size() int {
	if w.passthrough {
		return w.ResponseWriter.Size()
	}
	return w.body.Len()
}

func (w *responseCaptureWriter) Written() bool {
	return w.wroteHeader || w.body.Len() > 0 || w.passthrough
}

func (w *responseCaptureWriter) Flush() {
	if !w.passthrough {
		w.passthrough = true
		w.forward(w.body.Bytes())
		w.body.Reset()
	}
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *responseCaptureWriter) CloseNotify() <-chan bool {
	return w.ResponseWriter.CloseNotify()
}

func (w *responseCaptureWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	w.passthrough = true
	w.forward(w.body.Bytes())
	w.body.Reset()
	return w.ResponseWriter.Hijack()
}

func (w *responseCaptureWriter) Pusher() http.Pusher {
	return w.ResponseWriter.Pusher()
}

func (w *responseCaptureWriter) forward(body []byte) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	w.ResponseWriter.WriteHeader(w.status)
	if len(body) > 0 {
		_, _ = w.ResponseWriter.Write(body)
	}
}
