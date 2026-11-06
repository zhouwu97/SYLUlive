package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type EmojiPackSubmissionHandler struct {
	service     *services.EmojiPackService
	uploadSlots chan struct{}
}

func NewEmojiPackSubmissionHandler(service *services.EmojiPackService) *EmojiPackSubmissionHandler {
	return &EmojiPackSubmissionHandler{service: service, uploadSlots: make(chan struct{}, 2)}
}

func (h *EmojiPackSubmissionHandler) admin(c *gin.Context) bool {
	var user models.User
	return c.GetUint("user_id") != 0 && h.service.DB.WithContext(c.Request.Context()).Select("id", "role", "account_status").First(&user, c.GetUint("user_id")).Error == nil && (user.AccountStatus == "active" || user.AccountStatus == "") && (user.Role == "admin" || user.Role == "super_admin")
}

func (h *EmojiPackSubmissionHandler) Submit(c *gin.Context) {
	if c.GetUint("user_id") == 0 {
		c.JSON(401, gin.H{"error": "请先登录"})
		return
	}
	if err := h.service.RequireCreator(c.Request.Context(), c.GetUint("user_id")); err != nil {
		emojiPackError(c, err)
		return
	}
	select {
	case h.uploadSlots <- struct{}{}:
		defer func() { <-h.uploadSlots }()
	default:
		c.Header("Retry-After", "5")
		c.JSON(503, gin.H{"error": "上传繁忙，请稍后重试", "code": "emoji_upload_busy"})
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, services.EmojiPackMaxUploadBytes)
	err := c.Request.ParseMultipartForm(2 * 1024 * 1024)
	if c.Request.MultipartForm != nil {
		defer c.Request.MultipartForm.RemoveAll()
	}
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			c.JSON(413, gin.H{"error": "上传总大小不能超过 50 MB", "code": "emoji_pack_too_large"})
		} else {
			c.JSON(400, gin.H{"error": "上传内容无效"})
		}
		return
	}
	form := c.Request.MultipartForm
	if form == nil || c.PostForm("rights_confirmed") != "true" {
		c.JSON(400, gin.H{"error": "请先确认有权公开分享这些表情", "code": "emoji_rights_required"})
		return
	}
	files := form.File["images"]
	var names []string
	if len(files) < 1 || len(files) > services.EmojiPackMaxAssets || json.Unmarshal([]byte(c.PostForm("names")), &names) != nil || len(names) != len(files) {
		c.JSON(400, gin.H{"error": "请选择 1–100 张表情图片"})
		return
	}
	images := make([]services.EmojiPackUploadImage, 0, len(files))
	options := services.EmojiPackSubmissionOptions{FamilyID: c.PostForm("pack_id")}
	if raw := c.PostForm("cover_index"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil {
			emojiPackError(c, services.ErrEmojiPackInvalid)
			return
		}
		options.CoverIndex = value
	}
	options.IconIndex = options.CoverIndex
	if raw := c.PostForm("icon_index"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil {
			emojiPackError(c, services.ErrEmojiPackInvalid)
			return
		}
		options.IconIndex = value
	}
	if raw := c.PostForm("tags"); raw != "" && json.Unmarshal([]byte(raw), &options.Tags) != nil {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	for index, header := range files {
		if header.Size > services.EmojiMaxCompressedBytes {
			c.JSON(413, gin.H{"error": "单张表情不能超过 10 MB"})
			return
		}
		file, err := header.Open()
		if err != nil {
			emojiPackError(c, err)
			return
		}
		data, readErr := io.ReadAll(io.LimitReader(file, services.EmojiMaxCompressedBytes+1))
		_ = file.Close()
		if readErr != nil {
			emojiPackError(c, readErr)
			return
		}
		images = append(images, services.EmojiPackUploadImage{Name: names[index], Bytes: data})
	}
	pack, err := h.service.Submit(c.Request.Context(), c.GetUint("user_id"), c.GetHeader("Idempotency-Key"), c.PostForm("name"), c.PostForm("description"), images, options)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	pack.Assets = nil
	c.JSON(http.StatusOK, pack)
}

func emojiPackError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(404, gin.H{"error": "表情包不存在或不可访问", "code": "emoji_pack_not_found"})
	case errors.Is(err, services.ErrEmojiPackInvalid):
		c.JSON(400, gin.H{"error": err.Error(), "code": "emoji_pack_invalid"})
	case errors.Is(err, services.ErrEmojiPackConflict):
		c.JSON(409, gin.H{"error": err.Error(), "code": "emoji_pack_conflict"})
	case errors.Is(err, services.ErrEmojiPackQuota):
		c.JSON(429, gin.H{"error": err.Error(), "code": "emoji_pack_quota"})
	case errors.Is(err, services.ErrEmojiPackForbidden):
		c.JSON(403, gin.H{"error": err.Error(), "code": "admin_required"})
	case errors.Is(err, services.ErrEmojiCreatorRequired):
		c.JSON(403, gin.H{"error": err.Error(), "code": "emoji_creator_required"})
	default:
		c.JSON(500, gin.H{"error": "表情包操作失败，请重试", "code": "emoji_pack_failed"})
	}
}

func (h *EmojiPackSubmissionHandler) ListMine(c *gin.Context)  { h.list(c, false) }
func (h *EmojiPackSubmissionHandler) ListAdmin(c *gin.Context) { h.list(c, true) }
func (h *EmojiPackSubmissionHandler) list(c *gin.Context, admin bool) {
	if c.GetUint("user_id") == 0 {
		c.JSON(401, gin.H{"error": "请先登录"})
		return
	}
	if admin && !h.admin(c) {
		emojiPackError(c, services.ErrEmojiPackForbidden)
		return
	}
	query := h.service.DB.WithContext(c.Request.Context()).Model(&models.CommunityEmojiPack{})
	if !admin {
		query = query.Where("user_id = ?", c.GetUint("user_id"))
	}
	status := c.Query("status")
	if admin && status == "" {
		status = models.EmojiPackPending
	}
	if status != "" {
		if status != models.EmojiPackPending && status != models.EmojiPackPublished && status != models.EmojiPackRejected && status != models.EmojiPackUnpublished && status != models.EmojiPackWithdrawn && status != models.EmojiPackSuperseded {
			emojiPackError(c, services.ErrEmojiPackInvalid)
			return
		}
		query = query.Where("status = ?", status)
	}
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	if page < 1 || page > 100000 || limit < 1 || limit > 50 {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	var total int64
	if err := query.Count(&total).Error; err != nil {
		emojiPackError(c, err)
		return
	}
	items := []models.CommunityEmojiPack{}
	if err := query.Omit("manifest", "request_key", "content_hash").Order("created_at DESC, id DESC").Offset((page - 1) * limit).Limit(limit).Find(&items).Error; err != nil {
		emojiPackError(c, err)
		return
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(200, gin.H{"items": items, "total": total, "page": page, "limit": limit})
}

func (h *EmojiPackSubmissionHandler) privatePack(c *gin.Context) (*models.CommunityEmojiPack, error) {
	var pack models.CommunityEmojiPack
	query := h.service.DB.WithContext(c.Request.Context()).Where("id = ?", c.Param("id"))
	admin := h.admin(c)
	if strings.HasPrefix(c.Request.URL.Path, "/api/admin/") && !admin {
		return nil, services.ErrEmojiPackForbidden
	}
	if !admin {
		query = query.Where("user_id = ?", c.GetUint("user_id"))
	}
	if err := query.Preload("Assets", func(db *gorm.DB) *gorm.DB { return db.Order("id ASC") }).First(&pack).Error; err != nil {
		return nil, err
	}
	return &pack, nil
}

func (h *EmojiPackSubmissionHandler) Detail(c *gin.Context) {
	pack, err := h.privatePack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	c.Header("Cache-Control", "private, no-store")
	c.JSON(200, pack)
}

func (h *EmojiPackSubmissionHandler) Review(c *gin.Context) {
	if !h.admin(c) {
		emojiPackError(c, services.ErrEmojiPackForbidden)
		return
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 4096)
	var input struct {
		Action string `json:"action"`
		Reason string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		emojiPackError(c, services.ErrEmojiPackInvalid)
		return
	}
	if err := h.service.Review(c.Request.Context(), c.Param("id"), c.GetUint("user_id"), input.Action, input.Reason); err != nil {
		emojiPackError(c, err)
		return
	}
	c.JSON(200, gin.H{"message": "处理成功"})
}

func (h *EmojiPackSubmissionHandler) Withdraw(c *gin.Context) {
	if err := h.service.Withdraw(c.Request.Context(), c.Param("id"), c.GetUint("user_id")); err != nil {
		emojiPackError(c, err)
		return
	}
	c.JSON(200, gin.H{"message": "已撤回"})
}

func (h *EmojiPackSubmissionHandler) ServePrivateAsset(c *gin.Context) {
	pack, err := h.privatePack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	if pack.Status == models.EmojiPackWithdrawn {
		emojiPackError(c, gorm.ErrRecordNotFound)
		return
	}
	h.serveAsset(c, pack.ID, true)
}

func (h *EmojiPackSubmissionHandler) serveAsset(c *gin.Context, id string, private bool) {
	if c.Query("variant") != "" {
		if c.Query("variant") != "thumbnail" {
			emojiPackError(c, gorm.ErrRecordNotFound)
			return
		}
		var pack models.CommunityEmojiPack
		if err := h.service.DB.WithContext(c.Request.Context()).First(&pack, "id = ?", id).Error; err != nil {
			emojiPackError(c, err)
			return
		}
		h.servePreview(c, pack, c.Param("assetId"), "thumbnail", private)
		return
	}
	file, asset, err := h.service.OpenAsset(c.Request.Context(), id, c.Param("assetId"))
	if err != nil {
		emojiPackError(c, gorm.ErrRecordNotFound)
		return
	}
	defer file.Close()
	c.Header("Cache-Control", "no-store")
	if private {
		c.Header("Cache-Control", "private, no-store")
	}
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("Content-Type", asset.MimeType)
	c.Header("ETag", `"`+asset.SHA256+`"`)
	http.ServeContent(c.Writer, c.Request, asset.AssetID, time.Time{}, file)
}

func communityEmojiCatalogEntry(pack models.CommunityEmojiPack) gin.H {
	previews := make([]string, 0, 4)
	for i := 1; i <= pack.AssetCount && i <= 4; i++ {
		previews = append(previews, fmt.Sprintf("image-%d", i))
	}
	return gin.H{"id": pack.CatalogID(), "name": pack.Name, "description": pack.Description, "version": pack.Version, "source": "community", "asset_count": pack.AssetCount, "total_size": pack.TotalSize, "manifest_sha256": pack.ManifestSHA256,
		"cover_asset_id": pack.CoverAssetID, "icon_asset_id": pack.IconAssetID, "author_name": pack.AuthorName, "tags": pack.Tags, "media_version": 1, "preview_asset_ids": previews}
}

func (h *EmojiPackSubmissionHandler) ListCatalog(c *gin.Context) {
	items := make([]any, 0, len(officialEmojiPacks))
	for _, pack := range officialEmojiPacks {
		items = append(items, pack)
	}
	c.Header("Cache-Control", "no-store")
	// 旧客户端把目录资源一律作为 official 发送，不能让它们误领社区资源身份。
	if c.Query("include_community") != "true" {
		c.JSON(200, items)
		return
	}
	packs := []models.CommunityEmojiPack{}
	if err := h.service.DB.WithContext(c.Request.Context()).Omit("manifest", "request_key", "content_hash").Where("status = ?", models.EmojiPackPublished).Order("created_at DESC, id DESC").Find(&packs).Error; err != nil {
		emojiPackError(c, err)
		return
	}
	for _, pack := range packs {
		items = append(items, communityEmojiCatalogEntry(pack))
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(200, items)
}

func (h *EmojiPackSubmissionHandler) publicPack(c *gin.Context) (*models.CommunityEmojiPack, error) {
	var pack models.CommunityEmojiPack
	id := c.Param("id")
	query := h.service.DB.WithContext(c.Request.Context())
	if err := query.Where("(id = ? OR family_id = ?) AND status = ?", id, id, models.EmojiPackPublished).First(&pack).Error; err != nil {
		return nil, err
	}
	if pack.CatalogID() != id {
		return nil, gorm.ErrRecordNotFound
	}
	if raw := c.Query("version"); raw != "" {
		version, err := strconv.Atoi(raw)
		if err != nil || version < 1 {
			return nil, gorm.ErrRecordNotFound
		}
		if version != pack.Version {
			var previous models.CommunityEmojiPack
			if err := query.Where("(id = ? OR family_id = ?) AND version = ? AND status = ?", id, id, version, models.EmojiPackSuperseded).First(&previous).Error; err != nil {
				return nil, err
			}
			pack = previous
		}
	}
	return &pack, nil
}

func (h *EmojiPackSubmissionHandler) servePreview(c *gin.Context, pack models.CommunityEmojiPack, assetID, variant string, private bool) {
	data, err := h.service.OpenPreview(c.Request.Context(), pack, assetID, variant)
	if err != nil {
		emojiPackError(c, gorm.ErrRecordNotFound)
		return
	}
	c.Header("Cache-Control", "no-store")
	if private {
		c.Header("Cache-Control", "private, no-store")
	}
	c.Header("X-Content-Type-Options", "nosniff")
	c.Data(200, "image/png", data)
}

func (h *EmojiPackSubmissionHandler) ServePublicCover(c *gin.Context) {
	pack, err := h.publicPack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	variant := c.DefaultQuery("variant", "cover")
	if variant != "cover" && variant != "icon" {
		emojiPackError(c, gorm.ErrRecordNotFound)
		return
	}
	h.servePreview(c, *pack, "", variant, false)
}

func (h *EmojiPackSubmissionHandler) ServePrivateCover(c *gin.Context) {
	pack, err := h.privatePack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	if pack.Status == models.EmojiPackWithdrawn {
		emojiPackError(c, gorm.ErrRecordNotFound)
		return
	}
	variant := c.DefaultQuery("variant", "cover")
	if variant != "cover" && variant != "icon" {
		emojiPackError(c, gorm.ErrRecordNotFound)
		return
	}
	h.servePreview(c, *pack, "", variant, true)
}

func (h *EmojiPackSubmissionHandler) GetCatalogPack(c *gin.Context) {
	if !strings.HasPrefix(c.Param("id"), "community-") {
		GetEmojiPack(c)
		return
	}
	pack, err := h.publicPack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(200, communityEmojiCatalogEntry(*pack))
}
func (h *EmojiPackSubmissionHandler) GetManifest(c *gin.Context) {
	if !strings.HasPrefix(c.Param("id"), "community-") {
		GetEmojiPackManifest(c)
		return
	}
	pack, err := h.publicPack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	c.Header("Cache-Control", "no-store")
	c.Header("ETag", fmt.Sprintf(`"%s"`, pack.ManifestSHA256))
	c.Data(200, "application/json; charset=utf-8", pack.Manifest)
}
func (h *EmojiPackSubmissionHandler) ServePublicAsset(c *gin.Context) {
	if !strings.HasPrefix(c.Param("id"), "community-") {
		GetEmojiPackAsset(c)
		return
	}
	pack, err := h.publicPack(c)
	if err != nil {
		emojiPackError(c, err)
		return
	}
	h.serveAsset(c, pack.ID, false)
}
