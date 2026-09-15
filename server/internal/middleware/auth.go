package middleware

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

const tokenVersionCacheTTL = 60 * time.Second

type cachedSessionState struct {
	tokenVersion      int
	role              models.Role
	accountStatus     string
	legalConsentState models.LegalConsentState
	expiresAt         time.Time
}

var tokenVersionCache = struct {
	sync.Mutex
	values map[uint]cachedSessionState
}{
	values: make(map[uint]cachedSessionState),
}

const (
	LegalConsentEnforcementOff  = "off"
	LegalConsentEnforcementSoft = "soft"
	LegalConsentEnforcementHard = "hard"
)

var legalConsentEnforcement = LegalConsentEnforcementSoft

var jwtValidMethods = jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()})

// SetLegalConsentEnforcement 配置授权门禁模式；release 配置会强制使用 hard。
func SetLegalConsentEnforcement(mode string) {
	switch mode {
	case LegalConsentEnforcementOff, LegalConsentEnforcementSoft, LegalConsentEnforcementHard:
		legalConsentEnforcement = mode
	default:
		legalConsentEnforcement = LegalConsentEnforcementSoft
	}
}

// Claims JWT声明
type Claims struct {
	UserID       uint   `json:"user_id"`
	Role         string `json:"role"`
	TokenVersion int    `json:"token_version"`
	SessionID    string `json:"session_id,omitempty"`
	jwt.RegisteredClaims
}

// AuthMiddleware JWT认证中间件
func AuthMiddleware(db *gorm.DB, jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		// 只有通过所有前置门禁才清除此标记，避免幂等层永久重放认证拒绝。
		c.Set("idempotency_auth_rejected", true)
		tokenString := tokenFromRequest(c)

		if tokenString == "" {
			writeAPIError(c, http.StatusUnauthorized, "authentication_required", "未登录")
			c.Abort()
			return
		}
		claims := &Claims{}

		token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
			if token.Method != jwt.SigningMethodHS256 {
				return nil, fmt.Errorf("unexpected JWT signing method")
			}
			return []byte(jwtSecret), nil
		}, jwtValidMethods)

		if err != nil || !token.Valid {
			writeAPIError(c, http.StatusUnauthorized, "invalid_token", "无效的令牌")
			c.Abort()
			return
		}

		// 会话状态同时承载令牌版本和授权状态，避免业务接口分别遗漏校验。
		state, err := getCachedSessionState(db, claims.UserID)
		if err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				writeAPIError(c, http.StatusUnauthorized, "authentication_required", "用户不存在")
			} else {
				writeAPIError(c, http.StatusServiceUnavailable, "auth_service_unavailable", "认证服务暂时不可用")
			}
			c.Abort()
			return
		}
		if state.tokenVersion != claims.TokenVersion {
			writeAPIError(c, http.StatusUnauthorized, "token_version_expired", "账号状态已更新，请重新登录")
			c.Abort()
			return
		}
		if state.role != models.Role(claims.Role) {
			writeAPIError(c, http.StatusUnauthorized, "role_changed", "账号权限已更新，请重新登录")
			c.Abort()
			return
		}
		if state.accountStatus != "" && state.accountStatus != "active" {
			writeAPIError(c, http.StatusUnauthorized, "account_unavailable", "账号当前不可用")
			c.Abort()
			return
		}
		if claims.SessionID != "" {
			active, err := isSessionActive(db, claims.UserID, claims.SessionID)
			if err != nil {
				writeAPIError(c, http.StatusServiceUnavailable, "auth_service_unavailable", "认证服务暂时不可用")
				c.Abort()
				return
			}
			if !active {
				writeAPIError(c, http.StatusUnauthorized, "session_revoked", "当前设备登录已退出")
				c.Abort()
				return
			}
		}

		c.Set("user_id", claims.UserID)
		c.Set("role", string(state.role))
		c.Set("session_id", claims.SessionID)
		// 社区规则确认门禁不在这里按路径前缀猜，而是由 RequireCommunityRules
		// 显式挂在需要门禁的路由组上（见 community_rules.go）。
		if state.legalConsentState != models.LegalConsentStateActive && !isLegalConsentExemptRequest(c) {
			switch legalConsentEnforcement {
			case LegalConsentEnforcementHard:
				if state.legalConsentState == models.LegalConsentStateRequired {
					writeAPIError(c, http.StatusForbidden, "legal_consent_required", "请先确认最新协议与隐私政策")
				} else {
					writeAPIError(c, http.StatusForbidden, "legal_consent_withdrawn", "授权已撤销，当前功能不可用")
				}
				c.Abort()
				return
			case LegalConsentEnforcementSoft:
				log.Printf("[LEGAL_CONSENT_SOFT] user_id=%d method=%s route=%s state=%s client_version=%q", claims.UserID, c.Request.Method, c.Request.URL.Path, state.legalConsentState, clientVersion(c))
			}
		}
		c.Set("idempotency_auth_rejected", false)
		c.Next()
	}
}

// OptionalAuthMiddleware 可选JWT认证中间件。hard 模式下未授权用户访问公开接口时按匿名处理。
func OptionalAuthMiddleware(db *gorm.DB, jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		tokenString := tokenFromRequest(c)

		if tokenString != "" {
			claims := &Claims{}
			token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
				if token.Method != jwt.SigningMethodHS256 {
					return nil, fmt.Errorf("unexpected JWT signing method")
				}
				return []byte(jwtSecret), nil
			}, jwtValidMethods)
			if err == nil && token.Valid {
				if state, err := getCachedSessionState(db, claims.UserID); err == nil {
					if state.tokenVersion != claims.TokenVersion || state.role != models.Role(claims.Role) {
						c.Next()
						return
					}
					if state.accountStatus != "" && state.accountStatus != "active" {
						c.Next()
						return
					}
					if claims.SessionID != "" {
						active, sessionErr := isSessionActive(db, claims.UserID, claims.SessionID)
						if sessionErr != nil || !active {
							c.Next()
							return
						}
					}
					if state.legalConsentState != models.LegalConsentStateActive && legalConsentEnforcement == LegalConsentEnforcementSoft {
						log.Printf("[LEGAL_CONSENT_SOFT] optional user_id=%d method=%s route=%s state=%s client_version=%q", claims.UserID, c.Request.Method, c.Request.URL.Path, state.legalConsentState, clientVersion(c))
					}
					if legalConsentEnforcement != LegalConsentEnforcementHard || state.legalConsentState == models.LegalConsentStateActive {
						c.Set("user_id", claims.UserID)
						c.Set("role", string(state.role))
						c.Set("session_id", claims.SessionID)
					}
				}
			}
		}
		c.Next()
	}
}

func isSessionActive(db *gorm.DB, userID uint, sessionID string) (bool, error) {
	var active int64
	err := db.Model(&models.RefreshToken{}).
		Where("user_id = ? AND token_family = ? AND revoked_at IS NULL AND expires_at > ?", userID, sessionID, time.Now()).
		Count(&active).Error
	return active > 0, err
}

func getCachedTokenVersion(db *gorm.DB, userID uint) (int, error) {
	state, err := getCachedSessionState(db, userID)
	return state.tokenVersion, err
}

func getCachedSessionState(db *gorm.DB, userID uint) (cachedSessionState, error) {
	now := time.Now()
	tokenVersionCache.Lock()
	if cached, ok := tokenVersionCache.values[userID]; ok && now.Before(cached.expiresAt) {
		tokenVersionCache.Unlock()
		return cached, nil
	}
	tokenVersionCache.Unlock()

	var user models.User
	if err := db.Select("id", "token_version", "role", "account_status", "legal_consent_revoked_at", "edu_authorized").First(&user, userID).Error; err != nil {
		return cachedSessionState{}, err
	}
	legalConsentState, err := models.LegalConsentStateForUser(db, user)
	if err != nil {
		return cachedSessionState{}, err
	}

	state := cachedSessionState{
		tokenVersion:      user.TokenVersion,
		role:              user.Role,
		accountStatus:     user.AccountStatus,
		legalConsentState: legalConsentState,
		expiresAt:         now.Add(tokenVersionCacheTTL),
	}
	tokenVersionCache.Lock()
	tokenVersionCache.values[userID] = state
	tokenVersionCache.Unlock()
	return state, nil
}

func clearTokenVersionCacheForTest() {
	InvalidateTokenVersionCache(0)
}

// InvalidateTokenVersionCache 清除指定用户的令牌版本缓存。
func InvalidateTokenVersionCache(userID uint) {
	tokenVersionCache.Lock()
	if userID == 0 {
		tokenVersionCache.values = make(map[uint]cachedSessionState)
	} else {
		delete(tokenVersionCache.values, userID)
	}
	tokenVersionCache.Unlock()
}

// isLegalConsentExemptRequest 使用精确的 Method + Path 白名单，受限账号仅可办理隐私权利和退出操作。
func isLegalConsentExemptRequest(c *gin.Context) bool {
	method, path := c.Request.Method, c.Request.URL.Path
	switch {
	case method == http.MethodGet && path == "/api/user/profile":
		return true
	case method == http.MethodGet && path == "/api/user/privacy/data":
		return true
	case method == http.MethodGet && path == "/api/user/privacy/export":
		return true
	case method == http.MethodGet && path == "/api/user/privacy/requests":
		return true
	case method == http.MethodPost && path == "/api/user/privacy/requests":
		return true
	case method == http.MethodPost && path == "/api/user/legal-consents":
		return true
	case method == http.MethodDelete && path == "/api/user/privacy/consents":
		return true
	case method == http.MethodDelete && path == "/api/user/account":
		return true
	case method == http.MethodDelete && path == "/api/user/edu-binding":
		return true
	case method == http.MethodPut && path == "/api/user/push-settings":
		return true
	case method == http.MethodPost && path == "/api/logout":
		return true
	default:
		return false
	}
}

func clientVersion(c *gin.Context) string {
	if version := strings.TrimSpace(c.GetHeader("X-App-Version")); version != "" {
		return version
	}
	return strings.TrimSpace(c.GetHeader("User-Agent"))
}

func tokenFromRequest(c *gin.Context) string {
	authHeader := c.GetHeader("Authorization")
	if authHeader != "" {
		token := strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))
		if token != "" {
			return token
		}
	}

	if cookieToken, err := c.Cookie("jwt"); err == nil {
		return strings.TrimSpace(cookieToken)
	}
	return ""
}

// AdminMiddleware 管理员权限中间件
func AdminMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		role, _ := c.Get("role")
		if role != "admin" && role != "super_admin" {
			writeAPIError(c, http.StatusForbidden, "admin_required", "需要管理员权限")
			c.Abort()
			return
		}
		c.Next()
	}
}

// SuperAdminMiddleware 超级管理员权限中间件
func SuperAdminMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		role, _ := c.Get("role")
		if role != "super_admin" {
			writeAPIError(c, http.StatusForbidden, "super_admin_required", "需要超级管理员权限")
			c.Abort()
			return
		}
		c.Next()
	}
}

func writeAPIError(c *gin.Context, status int, code, message string) {
	WriteAPIError(c, status, code, message, nil)
}

// GenerateToken 生成JWT令牌
func GenerateToken(userID uint, role string, tokenVersion int, jwtSecret string, sessionID ...string) (string, error) {
	// 访问令牌短期有效，长期会话由 Refresh Token 续期。
	ttl := 30 * time.Minute
	if raw := strings.TrimSpace(os.Getenv("ACCESS_TOKEN_TTL")); raw != "" {
		if parsed, err := time.ParseDuration(raw); err == nil && parsed > 0 {
			ttl = parsed
		}
	}
	claims := &Claims{
		UserID:       userID,
		Role:         role,
		TokenVersion: tokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	if len(sessionID) > 0 {
		claims.SessionID = strings.TrimSpace(sessionID[0])
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(jwtSecret))
}
