package middleware

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

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
		var tokenString string
		if cookieToken, err := c.Cookie("jwt"); err == nil && cookieToken != "" {
			tokenString = cookieToken
		} else {
			authHeader := c.GetHeader("Authorization")
			if authHeader != "" {
				tokenString = strings.TrimPrefix(authHeader, "Bearer ")
			}
		}

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
		var user models.User
		if err := db.Select("token_version").First(&user, claims.UserID).Error; err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "用户不存在"})
			c.Abort()
			return
		}
		if user.TokenVersion != claims.TokenVersion {
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
		var tokenString string
		if cookieToken, err := c.Cookie("jwt"); err == nil && cookieToken != "" {
			tokenString = cookieToken
		} else {
			authHeader := c.GetHeader("Authorization")
			if authHeader != "" {
				tokenString = strings.TrimPrefix(authHeader, "Bearer ")
			}
		}

		if tokenString != "" {
			claims := &Claims{}
			token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
				return []byte(jwtSecret), nil
			})
			if err == nil && token.Valid {
				// 检查 TokenVersion
				var user models.User
				if err := db.Select("token_version").First(&user, claims.UserID).Error; err == nil {
					if user.TokenVersion == claims.TokenVersion {
						c.Set("user_id", claims.UserID)
						c.Set("role", claims.Role)
					}
				}
			}
		}
		c.Next()
	}
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
