package middleware

import (
	"net/http"
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
	legalConsentState models.LegalConsentState
	expiresAt         time.Time
}

var sessionStateCache = struct {
	sync.Mutex
	values map[uint]cachedSessionState
}{
	values: make(map[uint]cachedSessionState),
}

// Claims JWT声明
type Claims struct {
	UserID       uint   `json:"user_id"`
	Role         string `json:"role"`
	TokenVersion int    `json:"token_version"`
	jwt.RegisteredClaims
}

// AuthMiddleware JWT认证中间件
func AuthMiddleware(db *gorm.DB, jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		tokenString := tokenFromRequest(c)

		if tokenString == "" {
			writeAPIError(c, http.StatusUnauthorized, "authentication_required", "未登录")
			c.Abort()
			return
		}
		claims := &Claims{}

		token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
			return []byte(jwtSecret), nil
		})

		if err != nil || !token.Valid {
			writeAPIError(c, http.StatusUnauthorized, "invalid_token", "无效的令牌")
			c.Abort()
			return
		}

		// 会话状态同时承载令牌版本和授权撤销状态，避免业务接口各自遗漏校验。
		state, err := getCachedSessionState(db, claims.UserID)
		if err != nil {
			writeAPIError(c, http.StatusUnauthorized, "authentication_required", "用户不存在")
			c.Abort()
			return
		}
		if state.tokenVersion != claims.TokenVersion {
			writeAPIError(c, http.StatusUnauthorized, "token_version_expired", "账号状态已更新，请重新登录")
			c.Abort()
			return
		}

		c.Set("user_id", claims.UserID)
		c.Set("role", claims.Role)
		if state.legalConsentState != models.LegalConsentStateActive && !isLegalConsentExemptRequest(c) {
			if state.legalConsentState == models.LegalConsentStateRequired {
				writeAPIError(c, http.StatusForbidden, "legal_consent_required", "请先阅读并同意协议与隐私政策")
			} else {
				writeAPIError(c, http.StatusForbidden, "legal_consent_withdrawn", "你已撤销同意，当前功能不可用")
			}
			c.Abort()
			return
		}
		c.Next()
	}
}

// OptionalAuthMiddleware 可选JWT认证中间件（解析用户信息但不拦截）
func OptionalAuthMiddleware(db *gorm.DB, jwtSecret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		tokenString := tokenFromRequest(c)

		if tokenString != "" {
			claims := &Claims{}
			token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
				return []byte(jwtSecret), nil
			})
			if err == nil && token.Valid {
				// 撤销同意的账号访问公开接口时按匿名用户处理。
				if state, err := getCachedSessionState(db, claims.UserID); err == nil {
					if state.tokenVersion == claims.TokenVersion && state.legalConsentState == models.LegalConsentStateActive {
						c.Set("user_id", claims.UserID)
						c.Set("role", claims.Role)
					}
				}
			}
		}
		c.Next()
	}
}

func getCachedTokenVersion(db *gorm.DB, userID uint) (int, error) {
	state, err := getCachedSessionState(db, userID)
	return state.tokenVersion, err
}

func getCachedSessionState(db *gorm.DB, userID uint) (cachedSessionState, error) {
	now := time.Now()
	sessionStateCache.Lock()
	if cached, ok := sessionStateCache.values[userID]; ok && now.Before(cached.expiresAt) {
		sessionStateCache.Unlock()
		return cached, nil
	}
	sessionStateCache.Unlock()

	var user models.User
	if err := db.Select("id", "token_version", "legal_consent_revoked_at", "edu_bound").First(&user, userID).Error; err != nil {
		return cachedSessionState{}, err
	}
	legalConsentState, err := models.LegalConsentStateForUser(db, user)
	if err != nil {
		return cachedSessionState{}, err
	}

	state := cachedSessionState{
		tokenVersion:      user.TokenVersion,
		legalConsentState: legalConsentState,
		expiresAt:         now.Add(tokenVersionCacheTTL),
	}
	sessionStateCache.Lock()
	sessionStateCache.values[userID] = state
	sessionStateCache.Unlock()
	return state, nil
}

func clearTokenVersionCacheForTest() {
	InvalidateTokenVersionCache(0)
}

// InvalidateTokenVersionCache 清除指定用户的令牌版本缓存。
func InvalidateTokenVersionCache(userID uint) {
	sessionStateCache.Lock()
	if userID == 0 {
		sessionStateCache.values = make(map[uint]cachedSessionState)
	} else {
		delete(sessionStateCache.values, userID)
	}
	sessionStateCache.Unlock()
}

// 授权受限账号仍可查阅数据、完成协议确认、注销账号或退出登录。
func isLegalConsentExemptRequest(c *gin.Context) bool {
	path := c.Request.URL.Path
	return strings.HasPrefix(path, "/api/user/privacy/") ||
		path == "/api/user/profile" ||
		path == "/api/user/legal-consents" ||
		path == "/api/user/account" ||
		path == "/api/logout"
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
	c.JSON(status, gin.H{"error": message, "code": code})
}

// GenerateToken 生成JWT令牌
func GenerateToken(userID uint, role string, tokenVersion int, jwtSecret string) (string, error) {
	claims := &Claims{
		UserID:       userID,
		Role:         role,
		TokenVersion: tokenVersion,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(7 * 24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(jwtSecret))
}
