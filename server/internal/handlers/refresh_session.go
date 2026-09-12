package handlers

import (
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
)

func refreshTTL() time.Duration {
	if raw := strings.TrimSpace(os.Getenv("REFRESH_TOKEN_TTL")); raw != "" {
		if d, err := time.ParseDuration(raw); err == nil && d > 0 {
			return d
		}
	}
	return 30 * 24 * time.Hour
}

func accessTTL() time.Duration {
	if raw := strings.TrimSpace(os.Getenv("ACCESS_TOKEN_TTL")); raw != "" {
		if d, err := time.ParseDuration(raw); err == nil && d > 0 {
			return d
		}
	}
	return 30 * time.Minute
}

func randomRefreshToken() (string, error) {
	b := make([]byte, 32)
	if _, err := crand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func refreshHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

var errRefreshTokenReused = errors.New("refresh token already rotated")

func revokeRefreshTokensForUser(db *gorm.DB, userID uint) {
	if !db.Migrator().HasTable(&models.RefreshToken{}) {
		return
	}
	now := time.Now()
	_ = db.Model(&models.RefreshToken{}).Where("user_id = ? AND revoked_at IS NULL", userID).Update("revoked_at", now).Error
}

// 退出登录只撤销当前设备的刷新凭据，避免影响同一账号的其他设备。
func revokeRefreshToken(db *gorm.DB, raw string) {
	raw = strings.TrimSpace(raw)
	if raw == "" || !db.Migrator().HasTable(&models.RefreshToken{}) {
		return
	}
	now := time.Now()
	_ = db.Model(&models.RefreshToken{}).
		Where("token_hash = ? AND revoked_at IS NULL", refreshHash(raw)).
		Updates(map[string]interface{}{"revoked_at": now, "last_used_at": now})
}

func (h *AuthHandler) issueRefreshToken(userID uint, family string, c *gin.Context) (string, error) {
	return issueRefreshTokenForDB(h.db, userID, family, c)
}

func issueRefreshTokenForDB(db *gorm.DB, userID uint, family string, c *gin.Context) (string, error) {
	raw, err := randomRefreshToken()
	if err != nil {
		return "", err
	}
	if family == "" {
		family = raw
	}
	var user models.User
	if err := db.Select("id", "token_version").First(&user, userID).Error; err != nil {
		return "", err
	}
	row := &models.RefreshToken{UserID: userID, TokenVersion: user.TokenVersion, TokenHash: refreshHash(raw), TokenFamily: family, ExpiresAt: time.Now().Add(refreshTTL()), CreatedIPHash: refreshHash(c.ClientIP()), UserAgentHash: refreshHash(c.GetHeader("User-Agent"))}
	if err := db.Create(row).Error; err != nil {
		return "", err
	}
	return raw, nil
}

func (h *AuthHandler) Refresh(c *gin.Context) {
	if raw := strings.TrimSpace(os.Getenv("AUTH_REFRESH_ENABLED")); raw != "" && !strings.EqualFold(raw, "true") {
		c.JSON(404, gin.H{"error": "刷新会话未启用", "code": "refresh_disabled"})
		return
	}
	var input struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || strings.TrimSpace(input.RefreshToken) == "" {
		input.RefreshToken, _ = c.Cookie("refresh_token")
		if strings.TrimSpace(input.RefreshToken) == "" {
			c.JSON(400, gin.H{"error": "refresh_token required", "code": "invalid_refresh_token"})
			return
		}
	}
	var current models.RefreshToken
	if err := h.db.Where("token_hash = ?", refreshHash(input.RefreshToken)).First(&current).Error; err != nil {
		c.JSON(401, gin.H{"error": "刷新凭据无效", "code": "invalid_refresh_token"})
		return
	}
	now := time.Now()
	if current.RevokedAt != nil && current.ReplacedBy != nil {
		_ = h.db.Model(&models.RefreshToken{}).Where("token_family = ? AND revoked_at IS NULL", current.TokenFamily).Updates(map[string]interface{}{"revoked_at": now})
		c.JSON(401, gin.H{"error": "刷新凭据已重复使用", "code": "refresh_token_reused"})
		return
	}
	if current.RevokedAt != nil || !current.ExpiresAt.After(now) {
		c.JSON(401, gin.H{"error": "刷新凭据已失效", "code": "refresh_token_expired"})
		return
	}
	var user models.User
	if err := h.db.First(&user, current.UserID).Error; err != nil || user.AccountStatus != "active" {
		c.JSON(401, gin.H{"error": "账号不可用", "code": "invalid_refresh_token"})
		return
	}
	if user.TokenVersion != current.TokenVersion {
		c.JSON(401, gin.H{"error": "会话已失效", "code": "refresh_token_expired"})
		return
	}
	newRaw, err := randomRefreshToken()
	if err != nil {
		c.JSON(500, gin.H{"error": "无法生成会话"})
		return
	}
	newRow := &models.RefreshToken{UserID: user.ID, TokenVersion: user.TokenVersion, TokenHash: refreshHash(newRaw), TokenFamily: current.TokenFamily, ExpiresAt: now.Add(refreshTTL()), CreatedIPHash: refreshHash(c.ClientIP()), UserAgentHash: refreshHash(c.GetHeader("User-Agent"))}
	err = h.db.Transaction(func(tx *gorm.DB) error {
		result := tx.Model(&models.RefreshToken{}).Where("id = ? AND revoked_at IS NULL", current.ID).Updates(map[string]interface{}{"revoked_at": now, "last_used_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return errRefreshTokenReused
		}
		if err := tx.Create(newRow).Error; err != nil {
			return err
		}
		return tx.Model(&models.RefreshToken{}).Where("id = ?", current.ID).Update("replaced_by", newRow.ID).Error
	})
	if errors.Is(err, errRefreshTokenReused) {
		_ = h.db.Model(&models.RefreshToken{}).Where("token_family = ? AND revoked_at IS NULL", current.TokenFamily).Updates(map[string]interface{}{"revoked_at": now})
		c.JSON(401, gin.H{"error": "刷新凭据已重复使用", "code": "refresh_token_reused"})
		return
	}
	if err != nil {
		c.JSON(500, gin.H{"error": "刷新会话失败"})
		return
	}
	access, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret)
	if err != nil {
		c.JSON(500, gin.H{"error": "无法生成Token"})
		return
	}
	response, err := selfUserResponseForDB(h.db, user)
	if err != nil {
		c.JSON(500, gin.H{"error": "读取账号状态失败"})
		return
	}
	payload := authSessionPayload(c, access, response)
	payload["expires_at"] = now.Add(accessTTL())
	if !isCookieAuthTransport(c) {
		payload["refresh_token"] = newRaw
		payload["refresh_expires_at"] = newRow.ExpiresAt
	}
	secure := middleware.SecureCookieEnabled()
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("refresh_token", newRaw, int(refreshTTL().Seconds()), "/api", "", secure, true)
	c.SetCookie("jwt", access, int(accessTTL().Seconds()), "/api", "", secure, true)
	c.JSON(200, payload)
}
