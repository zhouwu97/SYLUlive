package middleware

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

const (
	idempotencyMaxKeyLength = 200
	idempotencyWaitTimeout  = 30 * time.Second
	idempotencyPollInterval = 25 * time.Millisecond
)

// IdempotencyMiddleware 为显式携带 Idempotency-Key 的写请求提供服务端去重。
//
// 这里只处理 POST/PUT/PATCH/DELETE；GET/HEAD 不建立记录，也不会被这个中间件
// 自动重放。没有键的旧客户端继续走原有业务路径，由业务接口自己的约束兜底。
func IdempotencyMiddleware(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		if db == nil || !isIdempotentWriteMethod(c.Request.Method) {
			c.Next()
			return
		}

		key := strings.TrimSpace(c.GetHeader("Idempotency-Key"))
		if key == "" {
			c.Next()
			return
		}
		if len(key) > idempotencyMaxKeyLength || strings.ContainsAny(key, "\r\n") {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
				"code":    "invalid_idempotency_key",
				"message": "Idempotency-Key 无效",
			})
			return
		}

		body, err := io.ReadAll(c.Request.Body)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
				"code":    "idempotency_body_unreadable",
				"message": "请求体无法读取",
			})
			return
		}
		c.Request.Body = io.NopCloser(bytes.NewReader(body))

		method := strings.ToUpper(c.Request.Method)
		path := c.Request.URL.RequestURI()
		requestHash := sha256Hex([]byte(method + "\n" + path + "\n" +
			string(canonicalIdempotencyBody(c.GetHeader("Content-Type"), body))))
		scope := idempotencyScope(c)
		expiresAt := time.Now().UTC().Add(24 * time.Hour)
		record := models.IdempotencyRecord{
			Scope: scope, Key: key, Method: method, Path: path,
			RequestHash: requestHash, State: models.IdempotencyStateProcessing,
			ExpiresAt: expiresAt,
		}

		if err := db.Create(&record).Error; err != nil {
			if replayIdempotentResponse(c, db, scope, key, method, path, requestHash) {
				return
			}
			c.AbortWithStatusJSON(http.StatusInternalServerError, gin.H{
				"code":    "idempotency_store_unavailable",
				"message": "请求幂等状态暂不可用",
			})
			return
		}

		capture := &idempotencyResponseWriter{ResponseWriter: c.Writer}
		c.Writer = capture
		defer func() {
			c.Writer = capture.ResponseWriter
			if recovered := recover(); recovered != nil {
				markIdempotencyFailed(db, record.ID)
				panic(recovered)
			}
		}()

		c.Next()
		status := capture.Status()
		if status <= 0 {
			status = http.StatusOK
		}
		if err := db.Model(&models.IdempotencyRecord{}).
			Where("id = ?", record.ID).
			Updates(map[string]interface{}{
				"state":         models.IdempotencyStateCompleted,
				"response_code": status,
				"content_type":  capture.Header().Get("Content-Type"),
				"response_body": append([]byte(nil), capture.body.Bytes()...),
			}).Error; err != nil {
			// 首个请求仍然返回业务响应，但日志会提示运维：后续重试无法重放。
			log.Printf("[IDEMPOTENCY_RESPONSE_STORE_FAILED] record_id=%d err=%v", record.ID, err)
		}
	}
}

func isIdempotentWriteMethod(method string) bool {
	switch strings.ToUpper(method) {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	default:
		return false
	}
}

func idempotencyScope(c *gin.Context) string {
	if userID, ok := c.Get("user_id"); ok {
		return fmt.Sprintf("user:%v", userID)
	}
	// 全局中间件位于路由级 AuthMiddleware 之前，因此匿名阶段不能直接读 user_id。
	// 令牌摘要既避免落库原始凭据，也避免不同登录态共用同一个键。
	credential := strings.TrimSpace(c.GetHeader("Authorization"))
	if credential == "" {
		if cookie, err := c.Request.Cookie("jwt"); err == nil {
			credential = cookie.Value
		}
	}
	if credential == "" {
		credential = c.ClientIP() + "\n" + c.GetHeader("User-Agent")
	}
	return "credential:" + sha256Hex([]byte(credential))
}

func replayIdempotentResponse(
	c *gin.Context,
	db *gorm.DB,
	scope, key, method, path, requestHash string,
) bool {
	var record models.IdempotencyRecord
	if err := db.Where(
		"scope = ? AND idempotency_key = ? AND method = ? AND path = ?",
		scope, key, method, path,
	).First(&record).Error; err != nil {
		return false
	}
	if record.RequestHash != requestHash {
		c.AbortWithStatusJSON(http.StatusConflict, gin.H{
			"code":    "idempotency_key_reused",
			"message": "Idempotency-Key 已用于不同请求",
		})
		return true
	}

	deadline := time.Now().Add(idempotencyWaitTimeout)
	for {
		switch record.State {
		case models.IdempotencyStateCompleted:
			if record.ContentType != "" {
				c.Header("Content-Type", record.ContentType)
			}
			c.AbortWithStatus(record.ResponseCode)
			if len(record.ResponseBody) > 0 {
				_, _ = c.Writer.Write(record.ResponseBody)
			}
			return true
		case models.IdempotencyStateFailed:
			c.AbortWithStatusJSON(http.StatusConflict, gin.H{
				"code":    "idempotency_request_failed",
				"message": "上一次请求未完成，请重新生成幂等键",
			})
			return true
		case models.IdempotencyStateProcessing:
			if !record.ExpiresAt.IsZero() && time.Now().After(record.ExpiresAt) {
				_ = db.Model(&models.IdempotencyRecord{}).
					Where("id = ? AND state = ?", record.ID, models.IdempotencyStateProcessing).
					Update("state", models.IdempotencyStateFailed).Error
				c.AbortWithStatusJSON(http.StatusConflict, gin.H{
					"code":    "idempotency_request_expired",
					"message": "上一次请求已过期，请重新生成幂等键",
				})
				return true
			}
		}
		if time.Now().After(deadline) {
			c.AbortWithStatusJSON(http.StatusConflict, gin.H{
				"code":    "idempotency_request_in_progress",
				"message": "相同请求仍在处理中，请稍后重试",
			})
			return true
		}
		time.Sleep(idempotencyPollInterval)
		if err := db.First(&record, record.ID).Error; err != nil {
			return false
		}
	}
}

func markIdempotencyFailed(db *gorm.DB, id uint) {
	if err := db.Model(&models.IdempotencyRecord{}).Where("id = ?", id).
		Update("state", models.IdempotencyStateFailed).Error; err != nil {
		log.Printf("[IDEMPOTENCY_FAILURE_STATE_STORE_FAILED] record_id=%d err=%v", id, err)
	}
}

func sha256Hex(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

// canonicalIdempotencyBody 去掉 multipart 每次构造都会变化的 boundary，
// 否则带图评论在同一幂等键重试时会被误判为“载荷变化”。
func canonicalIdempotencyBody(contentType string, body []byte) []byte {
	mediaType, params, err := mime.ParseMediaType(contentType)
	if err != nil || !strings.HasPrefix(strings.ToLower(mediaType), "multipart/") {
		return body
	}
	boundary := params["boundary"]
	if boundary == "" {
		return body
	}
	return bytes.ReplaceAll(body, []byte(boundary), []byte("__idempotency_boundary__"))
}

type idempotencyResponseWriter struct {
	gin.ResponseWriter
	body   bytes.Buffer
	status int
}

func (w *idempotencyResponseWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *idempotencyResponseWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	_, _ = w.body.Write(data)
	return w.ResponseWriter.Write(data)
}

func (w *idempotencyResponseWriter) WriteString(value string) (int, error) {
	return w.Write([]byte(value))
}
