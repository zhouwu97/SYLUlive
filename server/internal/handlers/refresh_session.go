package handlers

import (
	"crypto/hmac"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
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
var errRefreshRotationNotRecoverable = errors.New("refresh rotation cannot be recovered")

const refreshRotationRecoveryWindow = 30 * time.Second

func revokeRefreshTokensForUser(db *gorm.DB, userID uint) error {
	if !db.Migrator().HasTable(&models.RefreshToken{}) {
		return nil
	}
	now := time.Now()
	return db.Model(&models.RefreshToken{}).Where("user_id = ? AND revoked_at IS NULL", userID).Update("revoked_at", now).Error
}

// 退出登录只撤销当前设备的刷新凭据，避免影响同一账号的其他设备。
func revokeRefreshToken(db *gorm.DB, raw string) error {
	raw = strings.TrimSpace(raw)
	if raw == "" || !db.Migrator().HasTable(&models.RefreshToken{}) {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		var current models.RefreshToken
		if err := tx.Where("token_hash = ?", refreshHash(raw)).First(&current).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, current.UserID).Error; err != nil {
			return err
		}
		now := time.Now()
		return tx.Model(&models.RefreshToken{}).
			Where("id = ? AND revoked_at IS NULL", current.ID).
			Updates(map[string]interface{}{"revoked_at": now, "last_used_at": now}).Error
	})
}

func revokeRefreshTokenFamily(db *gorm.DB, userID uint, family string) error {
	family = strings.TrimSpace(family)
	if userID == 0 || family == "" || !db.Migrator().HasTable(&models.RefreshToken{}) {
		return nil
	}
	return db.Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}
		now := time.Now()
		return tx.Model(&models.RefreshToken{}).
			Where("user_id = ? AND token_family = ? AND revoked_at IS NULL", userID, family).
			Update("revoked_at", now).Error
	})
}

func (h *AuthHandler) issueRefreshSession(userID uint, c *gin.Context) (string, string, error) {
	return issueRefreshSessionForDB(h.db, userID, c)
}

func issueRefreshSessionForDB(db *gorm.DB, userID uint, c *gin.Context) (string, string, error) {
	return issueRefreshTokenRecordForDB(db, userID, "", c)
}

func issueRefreshTokenRecordForDB(db *gorm.DB, userID uint, family string, c *gin.Context) (string, string, error) {
	raw, err := randomRefreshToken()
	if err != nil {
		return "", "", err
	}
	if family == "" {
		family, err = randomRefreshToken()
		if err != nil {
			return "", "", err
		}
	}
	var user models.User
	if err := db.Select("id", "token_version").First(&user, userID).Error; err != nil {
		return "", "", err
	}
	var installHash string
	if installID := strings.TrimSpace(c.GetHeader("X-Installation-ID")); installID != "" {
		installHash = refreshHash(installID)
	}
	row := &models.RefreshToken{
		UserID:             userID,
		TokenVersion:       user.TokenVersion,
		TokenHash:          refreshHash(raw),
		TokenFamily:        family,
		FamilyVersion:      2,
		ExpiresAt:          time.Now().Add(refreshTTL()),
		CreatedIPHash:      refreshHash(c.ClientIP()),
		UserAgentHash:      refreshHash(c.GetHeader("User-Agent")),
		InstallationIDHash: installHash,
	}
	if err := db.Create(row).Error; err != nil {
		return "", "", err
	}
	return raw, family, nil
}

func rotationRefreshToken(secret, previousRaw string, previousID uint) string {
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte("refresh-rotation:"))
	_, _ = mac.Write([]byte(previousRaw))
	_, _ = mac.Write([]byte(":" + strconv.FormatUint(uint64(previousID), 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

func refreshRotationFamily(secret string, current models.RefreshToken, previousRaw string) string {
	if current.FamilyVersion >= 2 {
		return current.TokenFamily
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte("refresh-family-migration:"))
	_, _ = mac.Write([]byte(previousRaw))
	_, _ = mac.Write([]byte(":" + strconv.FormatUint(uint64(current.ID), 10)))
	return hex.EncodeToString(mac.Sum(nil))
}

func (h *AuthHandler) revokeRefreshRotationFamilies(current models.RefreshToken, previousRaw string) {
	_ = revokeRefreshTokenFamily(h.db, current.UserID, current.TokenFamily)
	migratedFamily := refreshRotationFamily(h.jwtSecret, current, previousRaw)
	if migratedFamily != current.TokenFamily {
		_ = revokeRefreshTokenFamily(h.db, current.UserID, migratedFamily)
	}
}

func (h *AuthHandler) recoverRefreshRotation(current models.RefreshToken, previousRaw string, c *gin.Context, now time.Time) (models.User, string, time.Time, error) {
	// 只用替代记录确认本次轮换的请求指纹；current.CreatedIPHash 属于旧签发网络，
	// 换网后的合法重试不应因此被当作重放攻击。IP 不承担设备身份证明职责。
	if current.RevokedAt == nil || current.ReplacedBy == nil || current.LastUsedAt == nil {
		return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
	}

	requestInstallID := strings.TrimSpace(c.GetHeader("X-Installation-ID"))
	var isSameInstallation bool
	if requestInstallID != "" && current.InstallationIDHash != "" {
		requestInstallHash := refreshHash(requestInstallID)
		if requestInstallHash != current.InstallationIDHash {
			// 明确携带了不同设备的安装标识，直接判定为重放攻击，不可恢复
			return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
		}
		isSameInstallation = true
	}

	// 若非同一个稳定安装标识重试，则必须受严格的短恢复窗口（30秒）限制
	if !isSameInstallation {
		if now.Sub(*current.LastUsedAt) < 0 || now.Sub(*current.LastUsedAt) > refreshRotationRecoveryWindow ||
			current.UserAgentHash == "" {
			return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
		}
	}

	newRaw := rotationRefreshToken(h.jwtSecret, previousRaw, current.ID)
	targetFamily := refreshRotationFamily(h.jwtSecret, current, previousRaw)
	var replacement models.RefreshToken
	if err := h.db.First(&replacement, *current.ReplacedBy).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
		}
		return models.User{}, "", time.Time{}, err
	}

	if isSameInstallation {
		if replacement.InstallationIDHash != current.InstallationIDHash {
			return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
		}
	} else {
		if replacement.UserAgentHash != refreshHash(c.GetHeader("User-Agent")) {
			return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
		}
	}

	if replacement.UserID != current.UserID || replacement.TokenFamily != targetFamily ||
		replacement.TokenHash != refreshHash(newRaw) || replacement.RevokedAt != nil ||
		!replacement.ExpiresAt.After(now) {
		return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
	}

	var user models.User
	if err := h.db.First(&user, current.UserID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
		}
		return models.User{}, "", time.Time{}, err
	}
	if user.AccountStatus != "active" || user.TokenVersion != current.TokenVersion ||
		user.TokenVersion != replacement.TokenVersion {
		return models.User{}, "", time.Time{}, errRefreshRotationNotRecoverable
	}
	return user, newRaw, replacement.ExpiresAt, nil
}

func (h *AuthHandler) prepareRefreshResponse(user models.User, family string) (string, SelfUserResponse, error) {
	access, err := middleware.GenerateToken(user.ID, string(user.Role), user.TokenVersion, h.jwtSecret, family)
	if err != nil {
		return "", SelfUserResponse{}, err
	}
	response, err := selfUserResponseForDB(h.db, user)
	if err != nil {
		return "", SelfUserResponse{}, err
	}
	return access, response, nil
}

func writeRefreshResponse(c *gin.Context, access string, response SelfUserResponse, refreshToken string, refreshExpiresAt, now time.Time) {
	payload := authSessionPayload(c, access, response)
	payload["expires_at"] = now.Add(accessTTL())
	if !isCookieAuthTransport(c) {
		payload["refresh_token"] = refreshToken
		payload["refresh_expires_at"] = refreshExpiresAt
	}
	secure := middleware.SecureCookieEnabled()
	c.SetSameSite(http.SameSiteLaxMode)
	c.SetCookie("refresh_token", refreshToken, int(refreshTTL().Seconds()), "/api", "", secure, true)
	c.SetCookie("jwt", access, int(accessTTL().Seconds()), "/api", "", secure, true)
	c.JSON(http.StatusOK, payload)
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
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(401, gin.H{"error": "刷新凭据无效", "code": "invalid_refresh_token"})
		} else {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
		}
		return
	}
	now := time.Now()
	if current.RevokedAt != nil && current.ReplacedBy != nil {
		user, newRaw, refreshExpiresAt, recoveryErr := h.recoverRefreshRotation(current, input.RefreshToken, c, now)
		if recoveryErr == nil {
			recoveredFamily := refreshRotationFamily(h.jwtSecret, current, input.RefreshToken)
			access, response, prepareErr := h.prepareRefreshResponse(user, recoveredFamily)
			if prepareErr != nil {
				c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
				return
			}
			writeRefreshResponse(c, access, response, newRaw, refreshExpiresAt, now)
			return
		}
		if !errors.Is(recoveryErr, errRefreshRotationNotRecoverable) {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
			return
		}
		h.revokeRefreshRotationFamilies(current, input.RefreshToken)
		c.JSON(401, gin.H{"error": "刷新凭据已重复使用", "code": "refresh_token_reused"})
		return
	}
	if current.RevokedAt != nil || !current.ExpiresAt.After(now) {
		c.JSON(401, gin.H{"error": "刷新凭据已失效", "code": "refresh_token_expired"})
		return
	}
	var user models.User
	if err := h.db.First(&user, current.UserID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(401, gin.H{"error": "账号不可用", "code": "invalid_refresh_token"})
		} else {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
		}
		return
	}
	if user.AccountStatus != "active" {
		c.JSON(401, gin.H{"error": "账号不可用", "code": "invalid_refresh_token"})
		return
	}
	if user.TokenVersion != current.TokenVersion {
		c.JSON(401, gin.H{"error": "会话已失效", "code": "refresh_token_expired"})
		return
	}
	// 轮换值可由旧凭据和服务端密钥重建，仅用于同设备短窗口内恢复“响应已丢失”。
	newRaw := rotationRefreshToken(h.jwtSecret, input.RefreshToken, current.ID)
	targetFamily := refreshRotationFamily(h.jwtSecret, current, input.RefreshToken)
	var newInstallHash string
	if installID := strings.TrimSpace(c.GetHeader("X-Installation-ID")); installID != "" {
		newInstallHash = refreshHash(installID)
	} else {
		newInstallHash = current.InstallationIDHash
	}
	newRow := &models.RefreshToken{
		UserID:             user.ID,
		TokenVersion:       user.TokenVersion,
		TokenHash:          refreshHash(newRaw),
		TokenFamily:        targetFamily,
		FamilyVersion:      2,
		ExpiresAt:          now.Add(refreshTTL()),
		CreatedIPHash:      refreshHash(c.ClientIP()),
		UserAgentHash:      refreshHash(c.GetHeader("User-Agent")),
		InstallationIDHash: newInstallHash,
	}
	// 所有可能依赖外部表结构的响应数据都在轮换提交前准备，避免提交后失败使客户端失去凭据。
	access, response, err := h.prepareRefreshResponse(user, targetFamily)
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
		return
	}
	err = h.db.Transaction(func(tx *gorm.DB) error {
		// 刷新与登出共同锁定用户行，确保登出不会漏掉本事务随后插入的替代令牌。
		var lockedUser models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&lockedUser, user.ID).Error; err != nil {
			return err
		}
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
		var rotated models.RefreshToken
		if reloadErr := h.db.First(&rotated, current.ID).Error; reloadErr != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
			return
		}
		recoveryNow := time.Now()
		recoveredUser, recoveredRaw, refreshExpiresAt, recoveryErr := h.recoverRefreshRotation(rotated, input.RefreshToken, c, recoveryNow)
		if recoveryErr == nil {
			recoveredFamily := refreshRotationFamily(h.jwtSecret, rotated, input.RefreshToken)
			recoveredAccess, recoveredResponse, prepareErr := h.prepareRefreshResponse(recoveredUser, recoveredFamily)
			if prepareErr != nil {
				c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
				return
			}
			writeRefreshResponse(c, recoveredAccess, recoveredResponse, recoveredRaw, refreshExpiresAt, now)
			return
		}
		if !errors.Is(recoveryErr, errRefreshRotationNotRecoverable) {
			c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
			return
		}
		h.revokeRefreshRotationFamilies(rotated, input.RefreshToken)
		c.JSON(401, gin.H{"error": "刷新凭据已重复使用", "code": "refresh_token_reused"})
		return
	}
	if err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "刷新服务暂时不可用", "code": "auth_service_unavailable"})
		return
	}
	writeRefreshResponse(c, access, response, newRaw, newRow.ExpiresAt, now)
}
