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

type cachedTokenVersion struct {
	version   int
	expiresAt time.Time
}

var tokenVersionCache = struct {
	sync.Mutex
	values map[uint]cachedTokenVersion
}{
	values: make(map[uint]cachedTokenVersion),
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
			c.JSON(http.StatusUnauthorized, gin.H{"error": "未登录"})
			c.Abort()
			return
		}
		claims := &Claims{}

		token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
			return []byte(jwtSecret), nil
		})

		if err != nil || !token.Valid {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "无效的令牌"})
			c.Abort()
			return
		}

		// 检查数据库中用户的 TokenVersion 是否一致
		tokenVersion, err := getCachedTokenVersion(db, claims.UserID)
		if err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
			c.Abort()
			return
		}
		if tokenVersion != claims.TokenVersion {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "账号密码已修改，请重新登录"})
			c.Abort()
			return
		}

		c.Set("user_id", claims.UserID)
		c.Set("role", claims.Role)
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
				// 检查 TokenVersion
				if tokenVersion, err := getCachedTokenVersion(db, claims.UserID); err == nil {
					if tokenVersion == claims.TokenVersion {
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
	now := time.Now()
	tokenVersionCache.Lock()
	if cached, ok := tokenVersionCache.values[userID]; ok && now.Before(cached.expiresAt) {
		tokenVersionCache.Unlock()
		return cached.version, nil
	}
	tokenVersionCache.Unlock()

	var user models.User
	if err := db.Select("token_version").First(&user, userID).Error; err != nil {
		return 0, err
	}

	tokenVersionCache.Lock()
	tokenVersionCache.values[userID] = cachedTokenVersion{
		version:   user.TokenVersion,
		expiresAt: now.Add(tokenVersionCacheTTL),
	}
	tokenVersionCache.Unlock()
	return user.TokenVersion, nil
}

func clearTokenVersionCacheForTest() {
	tokenVersionCache.Lock()
	tokenVersionCache.values = make(map[uint]cachedTokenVersion)
	tokenVersionCache.Unlock()
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
			c.JSON(http.StatusForbidden, gin.H{"error": "需要管理员权限"})
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
			c.JSON(http.StatusForbidden, gin.H{"error": "需要超级管理员权限"})
			c.Abort()
			return
		}
		c.Next()
	}
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
