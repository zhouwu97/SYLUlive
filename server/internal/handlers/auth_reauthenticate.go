package handlers

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

var errReauthenticationSession = errors.New("reauthentication session unavailable")

// Reauthenticate 仅给当前登录会话补充密码验证，不创建会话、延长令牌或批准助手权限。
func (h *AuthHandler) Reauthenticate(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	reject := func(status int, code, message string) {
		c.JSON(status, gin.H{"code": code, "message": message})
	}
	userID, family := c.GetUint("user_id"), c.GetString("session_id")
	if userID == 0 || family == "" {
		reject(http.StatusUnauthorized, "authentication_required", "登录状态已失效，请重新登录")
		return
	}
	var input struct {
		Password       string `json:"password"`
		ExpectedUserID uint   `json:"expected_user_id"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil || decoder.Decode(&struct{}{}) != io.EOF || input.Password == "" || len(input.Password) > 512 || input.ExpectedUserID == 0 {
		reject(http.StatusUnprocessableEntity, "invalid_request", "请输入当前账号的密码")
		return
	}
	if input.ExpectedUserID != userID {
		reject(http.StatusConflict, "auth_session_changed", "账号已切换，请重新核对当前账号")
		return
	}
	now := time.Now()
	accountKey := loginThrottleScope("reauth", strconv.FormatUint(uint64(userID), 10))
	ipKey := loginThrottleScope("ip", c.ClientIP())
	for _, scope := range []string{accountKey, ipKey} {
		if remaining, locked := h.loginLock(scope, now); locked {
			c.Header("Retry-After", strconv.Itoa(max(1, int(remaining.Seconds()))))
			reject(http.StatusTooManyRequests, "reauthentication_throttled", "验证次数过多，请在"+formatRetryAfterCN(remaining)+"后重试")
			return
		}
	}
	var verified models.User
	if err := h.db.WithContext(c.Request.Context()).First(&verified, userID).Error; err != nil {
		reject(http.StatusServiceUnavailable, "auth_service_unavailable", "暂时无法验证身份，请稍后重试")
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(verified.PasswordHash), []byte(input.Password)); err != nil {
		input.Password = ""
		lockFor := h.registerLoginFailure(accountKey, now)
		if value := h.registerLoginFailure(ipKey, now); value > lockFor {
			lockFor = value
		}
		if lockFor > 0 {
			c.Header("Retry-After", strconv.Itoa(max(1, int(lockFor.Seconds()))))
			reject(http.StatusTooManyRequests, "reauthentication_throttled", "验证次数过多，请在"+formatRetryAfterCN(lockFor)+"后重试")
		} else {
			reject(http.StatusForbidden, "reauthentication_failed", "密码不正确，请重新输入当前 SYLUlive 账号的密码")
		}
		return
	}
	input.Password = ""
	// 与刷新、退出和密码修改共享 user → refresh_token 锁顺序，防止已撤销会话被恢复。
	err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		var current models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&current, userID).Error; err != nil {
			return err
		}
		if current.PasswordHash != verified.PasswordHash || current.TokenVersion != verified.TokenVersion || (current.AccountStatus != "" && current.AccountStatus != "active") {
			return errReauthenticationSession
		}
		var session models.RefreshToken
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
			"user_id = ? AND token_family = ? AND token_version = ? AND revoked_at IS NULL AND expires_at > ?",
			userID, family, current.TokenVersion, now,
		).Order("created_at DESC, id DESC").Take(&session).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return errReauthenticationSession
			}
			return err
		}
		if err := tx.Model(&session).Update("authenticated_at", now).Error; err != nil {
			return err
		}
		metadata, _ := json.Marshal(map[string]string{
			"request_id": middleware.EnsureRequestID(c), "session_family_hash": refreshHash(family),
		})
		return tx.Create(&models.AccountSecurityAuditLog{UserID: userID, Action: "reauthentication_success", Metadata: string(metadata)}).Error
	})
	if errors.Is(err, errReauthenticationSession) {
		reject(http.StatusUnauthorized, "authentication_required", "登录状态已失效，请重新登录")
		return
	}
	if err != nil {
		reject(http.StatusServiceUnavailable, "auth_service_unavailable", "暂时无法保存验证结果，请稍后重试")
		return
	}
	h.clearLoginFailures(accountKey)
	c.JSON(http.StatusOK, gin.H{"authenticated": true, "user_id": userID, "valid_until": now.Add(integrationRecentAuthenticationWindow)})
}
