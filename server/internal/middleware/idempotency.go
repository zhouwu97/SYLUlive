package middleware

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

const (
	idempotencyMaxKeyLength = 200
	idempotencyMaxBodySize  = 1 << 20
	idempotencyWaitTimeout  = 30 * time.Second
	idempotencyPollInterval = 25 * time.Millisecond
)

// IdempotencyMiddleware 为显式携带 Idempotency-Key 的写请求提供服务端去重。
//
// 这里只处理 POST/PUT/PATCH/DELETE；GET/HEAD 不建立记录，也不会被这个中间件
// 自动重放。没有键的旧客户端继续走原有业务路径，由业务接口自己的约束兜底。
func IdempotencyMiddleware(db *gorm.DB) gin.HandlerFunc {
	return idempotencyMiddleware(db, "")
}

// IdempotencyMiddlewareWithJWT 在全局中间件位于 AuthMiddleware 之前时，
// 先验证 JWT 并使用稳定的 user_id 作为幂等范围。验证失败或匿名请求仍回退到
// credential/IP 范围，避免无效令牌污染有效用户的幂等记录。
func IdempotencyMiddlewareWithJWT(db *gorm.DB, jwtSecret string) gin.HandlerFunc {
	return idempotencyMiddleware(db, jwtSecret)
}

func idempotencyMiddleware(db *gorm.DB, jwtSecret string) gin.HandlerFunc {
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
		// 全局幂等中间件位于路由认证之前，先验证可用 JWT/当前会话状态，
		// 再读取请求体，避免未认证的大请求先消耗内存和 CPU。
		scope := idempotencyScopeWithJWT(c, db, jwtSecret)

		// 评论的文字和已上传附件 ID 也使用 multipart；沿用大小上限，不能按格式一律拒绝。
		if c.Request.ContentLength > idempotencyMaxBodySize {
			c.AbortWithStatusJSON(http.StatusRequestEntityTooLarge, gin.H{
				"code":    "idempotency_body_too_large",
				"message": "幂等请求体不能超过 1 MiB",
			})
			return
		}
		var body []byte
		var err error
		if c.Request.Body != nil {
			body, err = io.ReadAll(io.LimitReader(c.Request.Body, idempotencyMaxBodySize+1))
		}
		if err != nil {
			c.AbortWithStatusJSON(http.StatusBadRequest, gin.H{
				"code":    "idempotency_body_unreadable",
				"message": "请求体无法读取",
			})
			return
		}
		if len(body) > idempotencyMaxBodySize {
			c.AbortWithStatusJSON(http.StatusRequestEntityTooLarge, gin.H{
				"code":    "idempotency_body_too_large",
				"message": "幂等请求体不能超过 1 MiB",
			})
			return
		}
		c.Request.Body = io.NopCloser(bytes.NewReader(body))

		method := strings.ToUpper(c.Request.Method)
		path := c.Request.URL.RequestURI()
		requestHash := sha256Hex([]byte(method + "\n" + path + "\n" +
			string(canonicalIdempotencyBody(c.GetHeader("Content-Type"), body))))
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
		// 认证门禁尚未进入业务处理，确认协议或刷新会话后必须允许原键重试。
		if c.GetBool("idempotency_auth_rejected") {
			if err := db.Where("id = ? AND state = ?", record.ID, models.IdempotencyStateProcessing).
				Delete(&models.IdempotencyRecord{}).Error; err != nil {
				log.Printf("[IDEMPOTENCY_AUTH_RELEASE_FAILED] record_id=%d err=%v", record.ID, err)
			}
			return
		}
		status := capture.Status()
		if status <= 0 {
			status = http.StatusOK
		}
		result := db.Model(&models.IdempotencyRecord{}).
			Where("id = ? AND state = ?", record.ID, models.IdempotencyStateProcessing).
			Updates(map[string]interface{}{
				"state":         models.IdempotencyStateCompleted,
				"response_code": status,
				"content_type":  capture.Header().Get("Content-Type"),
				"response_body": append([]byte(nil), capture.body.Bytes()...),
			})
		if result.Error != nil {
			// 首个请求仍然返回业务响应，但日志会提示运维：后续重试无法重放。
			log.Printf("[IDEMPOTENCY_RESPONSE_STORE_FAILED] record_id=%d err=%v", record.ID, result.Error)
		} else if result.RowsAffected != 1 {
			// 清理任务或故障恢复已经接管了这条记录时，不能让迟到的业务响应
			// 把 failed 状态改回 completed，避免状态机倒退。
			log.Printf("[IDEMPOTENCY_RESPONSE_STATE_CHANGED] record_id=%d rows=%d", record.ID, result.RowsAffected)
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
	return idempotencyScopeWithJWT(c, nil, "")
}

func idempotencyScopeWithJWT(c *gin.Context, db *gorm.DB, jwtSecret string) string {
	if userID, ok := c.Get("user_id"); ok {
		return fmt.Sprintf("user:%v", userID)
	}
	if jwtSecret != "" {
		if userID, ok := authenticatedJWTUserID(c, db, jwtSecret); ok {
			return fmt.Sprintf("user:%d", userID)
		}
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

func authenticatedJWTUserID(c *gin.Context, db *gorm.DB, jwtSecret string) (uint, bool) {
	tokenString := tokenFromRequest(c)
	if tokenString == "" {
		return 0, false
	}
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected JWT signing method")
		}
		return []byte(jwtSecret), nil
	}, jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}))
	if err != nil || token == nil || !token.Valid || claims.UserID == 0 || db == nil {
		return 0, false
	}
	state, err := getCachedSessionState(db, claims.UserID)
	if err != nil || state.tokenVersion != claims.TokenVersion || state.role != models.Role(claims.Role) {
		return 0, false
	}
	return claims.UserID, true
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

// canonicalIdempotencyBody 按字段和附件内容校验 multipart，忽略传输 boundary，
// 不替换正文中的同名字节，避免不同内容被错误地视作同一请求。
func canonicalIdempotencyBody(contentType string, body []byte) []byte {
	mediaType, params, err := mime.ParseMediaType(contentType)
	if err == nil {
		lowerMediaType := strings.ToLower(mediaType)
		if lowerMediaType == "application/json" || strings.HasSuffix(lowerMediaType, "+json") {
			var value interface{}
			decoder := json.NewDecoder(bytes.NewReader(body))
			decoder.UseNumber()
			if err := decoder.Decode(&value); err == nil {
				var trailing interface{}
				if err := decoder.Decode(&trailing); err == io.EOF {
					if canonical, err := json.Marshal(value); err == nil {
						return canonical
					}
				}
			}
		}
	}
	if err != nil || !strings.HasPrefix(strings.ToLower(mediaType), "multipart/") {
		return body
	}
	boundary := params["boundary"]
	if boundary == "" {
		return body
	}
	type canonicalPart struct {
		Header map[string][]string
		Body   []byte
	}
	var parts []canonicalPart
	reader := multipart.NewReader(bytes.NewReader(body), boundary)
	for {
		part, err := reader.NextRawPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return body
		}
		data, err := io.ReadAll(part)
		if err != nil {
			return body
		}
		parts = append(parts, canonicalPart{Header: part.Header, Body: data})
	}
	canonical, err := json.Marshal(parts)
	if err != nil {
		return body
	}
	return canonical
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
