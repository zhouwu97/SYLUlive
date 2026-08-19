package handlers

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// EmojiFavoriteHandler 暴露账号级自定义表情收藏接口。
type EmojiFavoriteHandler struct {
	service *services.EmojiFavoriteService
}

func NewEmojiFavoriteHandler(service *services.EmojiFavoriteService) *EmojiFavoriteHandler {
	return &EmojiFavoriteHandler{service: service}
}

type emojiFavoriteRequest struct {
	Kind      string `json:"kind"`
	StickerID string `json:"sticker_id"`
	FileID    uint   `json:"file_id"`
	ImageURL  string `json:"image_url"`
	ImagePath string `json:"image_path"`
}

type emojiFavoriteMessageRequest struct {
	MessageID uint `json:"message_id"`
}

type emojiFavoritePublicImageRequest struct {
	ImageURL  string `json:"image_url"`
	ImagePath string `json:"image_path"`
}

func (h *EmojiFavoriteHandler) List(c *gin.Context) {
	items, err := h.service.List(c.Request.Context(), c.GetUint("user_id"))
	if err != nil {
		h.writeError(c, err)
		return
	}
	responseItems := make([]gin.H, 0, len(items))
	quotaUsed := int64(0)
	quotaLimit := services.MaxEmojiQuotaBytes
	favoriteLimit := services.MaxEmojiFavoriteCount
	for _, item := range items {
		responseItems = append(responseItems, emojiFavoriteJSON(item))
		quotaUsed = item.QuotaUsedBytes
		quotaLimit = item.QuotaLimitBytes
		favoriteLimit = item.FavoriteLimit
	}
	c.JSON(http.StatusOK, gin.H{
		"items":          responseItems,
		"quota_used":     quotaUsed,
		"quota_limit":    quotaLimit,
		"favorite_limit": favoriteLimit,
	})
}

func (h *EmojiFavoriteHandler) Create(c *gin.Context) {
	var input emojiFavoriteRequest
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "error": "请求格式无效"})
		return
	}
	userID := c.GetUint("user_id")
	var (
		item *services.EmojiFavoriteView
		err  error
	)
	switch strings.ToLower(strings.TrimSpace(input.Kind)) {
	case models.EmojiFavoriteKindBuiltin:
		if strings.TrimSpace(input.StickerID) == "" {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_sticker_id", "error": "缺少 sticker_id"})
			return
		}
		item, err = h.service.CreateBuiltin(c.Request.Context(), userID, input.StickerID)
	case models.EmojiFavoriteKindCustom, "image":
		if input.FileID > 0 {
			item, err = h.service.CreateCustom(c.Request.Context(), userID, input.FileID)
		} else if strings.TrimSpace(input.ImagePath) != "" {
			item, err = h.service.CreateFromPublicImage(c.Request.Context(), userID, input.ImagePath)
		} else if strings.TrimSpace(input.ImageURL) != "" {
			item, err = h.service.CreateFromPublicImage(c.Request.Context(), userID, input.ImageURL)
		} else {
			c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_file_id", "error": "缺少 file_id 或 image_url"})
			return
		}
	default:
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_kind", "error": "kind 必须是 builtin 或 custom"})
		return
	}
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, emojiFavoriteJSON(*item))
}

func (h *EmojiFavoriteHandler) CreateFromPublicImage(c *gin.Context) {
	var input emojiFavoritePublicImageRequest
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "error": "请求格式无效"})
		return
	}
	path := input.ImagePath
	if path == "" {
		path = input.ImageURL
	}
	if strings.TrimSpace(path) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_image_path", "error": "缺少 image_path 或 image_url"})
		return
	}
	item, err := h.service.CreateFromPublicImage(c.Request.Context(), c.GetUint("user_id"), path)
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, emojiFavoriteJSON(*item))
}

func (h *EmojiFavoriteHandler) CreateFromMessage(c *gin.Context) {
	var input emojiFavoriteMessageRequest
	if err := c.ShouldBindJSON(&input); err != nil || input.MessageID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_message_id", "error": "缺少 message_id"})
		return
	}
	item, err := h.service.CreateFromMessage(c.Request.Context(), c.GetUint("user_id"), input.MessageID)
	if err != nil {
		h.writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, emojiFavoriteJSON(*item))
}

func (h *EmojiFavoriteHandler) Delete(c *gin.Context) {
	favoriteID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || favoriteID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_favorite_id", "error": "收藏 ID 无效"})
		return
	}
	if err := h.service.Delete(c.Request.Context(), c.GetUint("user_id"), uint(favoriteID)); err != nil {
		h.writeError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *EmojiFavoriteHandler) ServeFile(c *gin.Context) {
	h.serveAsset(c, false)
}

func (h *EmojiFavoriteHandler) ServeThumbnail(c *gin.Context) {
	h.serveAsset(c, true)
}

func (h *EmojiFavoriteHandler) serveAsset(c *gin.Context, thumbnail bool) {
	favoriteID, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || favoriteID == 0 {
		c.Status(http.StatusNotFound)
		return
	}
	path, mimeType, err := h.service.ResolveFavoriteAsset(
		c.Request.Context(),
		c.GetUint("user_id"),
		uint(favoriteID),
		thumbnail,
	)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	if _, err := os.Stat(path); err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	c.Header("Content-Type", mimeType)
	c.Header("Cache-Control", "private, max-age=31536000")
	c.Header("X-Content-Type-Options", "nosniff")
	c.File(path)
}

func emojiFavoriteJSON(item services.EmojiFavoriteView) gin.H {
	result := gin.H{
		"id":              item.ID,
		"favorite_id":     item.FavoriteID,
		"user_id":         item.UserID,
		"kind":            item.Kind,
		"sort_order":      item.SortOrder,
		"quota_used":      item.QuotaUsedBytes,
		"quota_limit":     item.QuotaLimitBytes,
		"quota_remaining": item.QuotaRemainingBytes,
	}
	if item.StickerID != nil {
		result["sticker_id"] = *item.StickerID
	}
	if item.AssetID != nil {
		result["asset_id"] = *item.AssetID
	}
	if item.Asset != nil {
		result["mime_type"] = item.Asset.MimeType
		result["is_animated"] = item.Asset.IsAnimated
		result["thumbnail_url"] = fmt.Sprintf("/api/emoji/favorites/%d/thumbnail", item.ID)
	}
	if item.File != nil {
		result["file_id"] = item.File.ID
		result["url"] = fmt.Sprintf("/api/emoji/favorites/%d/file", item.ID)
		result["compressed_size"] = item.File.Size
		if _, ok := result["mime_type"]; !ok {
			result["mime_type"] = item.File.MimeType
		}
	}
	return result
}

func (h *EmojiFavoriteHandler) writeError(c *gin.Context, err error) {
	status := http.StatusInternalServerError
	code := "emoji_favorite_error"
	message := "表情收藏操作失败"
	switch {
	case errors.Is(err, services.ErrEmojiFavoriteLimit):
		status, code, message = http.StatusConflict, "emoji_favorite_limit_exceeded", "收藏数量已达上限"
	case errors.Is(err, services.ErrEmojiQuotaExceeded):
		status, code, message = http.StatusConflict, "emoji_quota_exceeded", "表情包空间已达 50MB 上限"
	case errors.Is(err, services.ErrEmojiDuplicate):
		status, code, message = http.StatusConflict, "emoji_duplicate", "该图片已在表情包中"
	case errors.Is(err, services.ErrEmojiMessageForbidden):
		status, code, message = http.StatusForbidden, "emoji_message_forbidden", "无权收藏这张图片"
	case errors.Is(err, services.ErrInvalidImageFileReference):
		status, code, message = http.StatusForbidden, "emoji_file_forbidden", "无权使用该图片文件"
	case errors.Is(err, gorm.ErrRecordNotFound):
		status, code, message = http.StatusNotFound, "emoji_favorite_not_found", "收藏不存在"
	}
	payload := gin.H{"code": code, "error": message, "message": message}
	if errors.Is(err, services.ErrEmojiQuotaExceeded) {
		used, limit, quotaErr := h.service.Quota(c.Request.Context(), c.GetUint("user_id"))
		if quotaErr == nil {
			payload["quota_used"] = used
			payload["quota_limit"] = limit
		}
	}
	c.JSON(status, payload)
}
