package handlers

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	neturl "net/url"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/models"
)

func oneClassAllowedUpdateScopes() map[string]struct{} {
	return map[string]struct{}{
		models.OneClassUpdateScopeAll:          {},
		models.OneClassUpdateScopeLifetimePlus: {},
		models.OneClassUpdateScopeLifetimeOnly: {},
		models.OneClassUpdateScopeUpgradeOnly:  {},
	}
}

func oneClassNormalizeUpdateScope(scope string) string {
	scope = strings.TrimSpace(scope)
	if scope == "" {
		return models.OneClassUpdateScopeLifetimePlus
	}
	if _, ok := oneClassAllowedUpdateScopes()[scope]; ok {
		return scope
	}
	return ""
}

func oneClassLicensePublicKey() (ed25519.PublicKey, error) {
	privateKey, err := oneClassLicensePrivateKey()
	if err != nil {
		return nil, err
	}
	publicKey, ok := privateKey.Public().(ed25519.PublicKey)
	if !ok || len(publicKey) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("OneClass 授权公钥无效")
	}
	return publicKey, nil
}

func oneClassParseLicenseToken(token string) (map[string]any, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("授权 token 格式无效")
	}
	signingInput := parts[0] + "." + parts[1]
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("授权 token 签名格式无效")
	}
	publicKey, err := oneClassLicensePublicKey()
	if err != nil {
		return nil, err
	}
	if !ed25519.Verify(publicKey, []byte(signingInput), signature) {
		return nil, fmt.Errorf("授权 token 签名无效")
	}
	payloadBytes, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("授权 token 载荷格式无效")
	}
	var payload map[string]any
	if err := json.Unmarshal(payloadBytes, &payload); err != nil {
		return nil, fmt.Errorf("授权 token 载荷解析失败")
	}
	if payload["typ"] != "oneclass_license" {
		return nil, fmt.Errorf("授权 token 类型无效")
	}
	return payload, nil
}

func oneClassUpdateScopesForTier(tier string) []string {
	switch tier {
	case models.OneClassTierLifetimeUpdates:
		return []string{
			models.OneClassUpdateScopeAll,
			models.OneClassUpdateScopeLifetimePlus,
			models.OneClassUpdateScopeLifetimeOnly,
		}
	case models.OneClassTierUpgradeUpdates:
		return []string{
			models.OneClassUpdateScopeAll,
			models.OneClassUpdateScopeLifetimePlus,
			models.OneClassUpdateScopeUpgradeOnly,
		}
	default:
		return []string{models.OneClassUpdateScopeAll}
	}
}

func (h *OneClassPayHandler) latestClientUpdateForTier(tier string) *models.OneClassUpdate {
	var update models.OneClassUpdate
	scopes := oneClassUpdateScopesForTier(tier)
	if err := h.db.
		Where("is_active = ? AND target_scope IN ?", true, scopes).
		Order("force_update DESC, created_at DESC").
		First(&update).Error; err != nil {
		return nil
	}
	return &update
}

func (h *OneClassPayHandler) currentClientUpdate(c *gin.Context) *models.OneClassUpdate {
	token := strings.TrimSpace(c.GetHeader("X-OneClass-License"))
	if token == "" {
		return nil
	}
	payload, err := oneClassParseLicenseToken(token)
	if err != nil {
		return nil
	}
	tier := strings.TrimSpace(fmt.Sprint(payload["tier"]))
	if tier != models.OneClassTierLifetimeUpdates && tier != models.OneClassTierUpgradeUpdates {
		return nil
	}
	return h.latestClientUpdateForTier(tier)
}

type oneClassUpdateInput struct {
	Title       string `json:"title" binding:"required"`
	Content     string `json:"content" binding:"required"`
	Version     string `json:"version"`
	DownloadURL string `json:"download_url"`
	TargetScope string `json:"target_scope"`
	ForceUpdate bool   `json:"force_update"`
	IsActive    *bool  `json:"is_active"`
}

func (h *OneClassPayHandler) AdminListUpdates(c *gin.Context) {
	var updates []models.OneClassUpdate
	if err := h.db.Preload("Creator").Order("created_at DESC").Find(&updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 OneClass 更新通知失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"updates": updates})
}

func (h *OneClassPayHandler) AdminCreateUpdate(c *gin.Context) {
	userID, _ := c.Get("user_id")
	var input oneClassUpdateInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	scope := oneClassNormalizeUpdateScope(input.TargetScope)
	if scope == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "target_scope 无效"})
		return
	}
	downloadURL := strings.TrimSpace(input.DownloadURL)
	if downloadURL != "" {
		parsed, err := neturl.ParseRequestURI(downloadURL)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "download_url 必须是完整 http/https 链接"})
			return
		}
	}
	isActive := true
	if input.IsActive != nil {
		isActive = *input.IsActive
	}
	update := models.OneClassUpdate{
		Title:       strings.TrimSpace(input.Title),
		Content:     strings.TrimSpace(input.Content),
		Version:     strings.TrimSpace(input.Version),
		DownloadURL: downloadURL,
		TargetScope: scope,
		ForceUpdate: input.ForceUpdate,
		IsActive:    isActive,
		CreatedBy:   userID.(uint),
	}
	if err := h.db.Create(&update).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建 OneClass 更新通知失败"})
		return
	}
	if err := h.db.Preload("Creator").First(&update, update.ID).Error; err != nil {
		c.JSON(http.StatusCreated, update)
		return
	}
	c.JSON(http.StatusCreated, update)
}

func (h *OneClassPayHandler) AdminUpdateUpdate(c *gin.Context) {
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "无效的更新通知 ID"})
		return
	}
	var existing models.OneClassUpdate
	if err := h.db.First(&existing, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "更新通知不存在"})
		return
	}
	var input oneClassUpdateInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	scope := oneClassNormalizeUpdateScope(input.TargetScope)
	if scope == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "target_scope 无效"})
		return
	}
	downloadURL := strings.TrimSpace(input.DownloadURL)
	if downloadURL != "" {
		parsed, err := neturl.ParseRequestURI(downloadURL)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "download_url 必须是完整 http/https 链接"})
			return
		}
	}
	updates := map[string]any{
		"title":        strings.TrimSpace(input.Title),
		"content":      strings.TrimSpace(input.Content),
		"version":      strings.TrimSpace(input.Version),
		"download_url": downloadURL,
		"target_scope": scope,
		"force_update": input.ForceUpdate,
	}
	if input.IsActive != nil {
		updates["is_active"] = *input.IsActive
	}
	if err := h.db.Model(&existing).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新 OneClass 通知失败"})
		return
	}
	if err := h.db.Preload("Creator").First(&existing, id).Error; err != nil {
		c.JSON(http.StatusOK, gin.H{"message": "ok"})
		return
	}
	c.JSON(http.StatusOK, existing)
}
