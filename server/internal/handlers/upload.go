package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// ValidatedImageMetadata 一次校验得到的完整图片元数据，避免对同一文件重复解码。
type ValidatedImageMetadata struct {
	MimeType string
	Width    int
	Height   int
}

// canonicalImageExt 根据检测出的真实 MIME 返回规范化扩展名，纠正
// “PNG 内容 + .jpg 文件名”这类 MIME/磁盘扩展名不一致的问题。
func canonicalImageExt(mimeType string) string {
	switch mimeType {
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	default: // image/jpeg 及未知的图片类型统一落到 .jpg
		return ".jpg"
	}
}

const (
	maxImageDimension = 12000
	maxImagePixels    = 50_000_000
)

func validateImageFile(src io.ReadSeeker) (ValidatedImageMetadata, error) {
	var meta ValidatedImageMetadata
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return meta, err
	}

	header := make([]byte, 512)
	n, _ := src.Read(header)
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		return meta, err
	}

	mimeType := http.DetectContentType(header[:n])
	switch mimeType {
	case "image/jpeg", "image/png", "image/gif":
	default:
		return meta, fmt.Errorf("只支持 jpg/png/gif 图片")
	}

	config, _, err := image.DecodeConfig(src)
	_, _ = src.Seek(0, io.SeekStart)
	if err != nil {
		return meta, fmt.Errorf("图片文件损坏或格式不支持")
	}

	if config.Width <= 0 || config.Height <= 0 {
		return meta, fmt.Errorf("图片尺寸无效")
	}
	if config.Width > maxImageDimension || config.Height > maxImageDimension ||
		int64(config.Width)*int64(config.Height) > maxImagePixels {
		return meta, fmt.Errorf("图片分辨率过高")
	}

	meta = ValidatedImageMetadata{
		MimeType: mimeType,
		Width:    config.Width,
		Height:   config.Height,
	}
	return meta, nil
}

func atomicWriteFile(dstPath string, src io.Reader) error {
	dir := filepath.Dir(dstPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("创建目录失败: %w", err)
	}
	tmpFile, err := os.CreateTemp(dir, "."+filepath.Base(dstPath)+".tmp-*")
	if err != nil {
		return fmt.Errorf("创建临时文件失败: %w", err)
	}
	tmpPath := tmpFile.Name()

	if _, err := io.Copy(tmpFile, src); err != nil {
		tmpFile.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("写入文件失败: %w", err)
	}
	if err := tmpFile.Sync(); err != nil {
		tmpFile.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("同步文件失败: %w", err)
	}
	if err := tmpFile.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("关闭临时文件失败: %w", err)
	}
	if err := os.Rename(tmpPath, dstPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("原子重命名失败: %w", err)
	}
	return nil
}

// UploadHandler 上传处理器
type UploadHandler struct {
	db        *gorm.DB
	uploadDir string
	maxSize   int64
	jwtSecret string
}

// NewUploadHandler 创建上传处理器
func NewUploadHandler(uploadDir string, maxSize int64, db *gorm.DB, jwtSecrets ...string) *UploadHandler {
	handler := &UploadHandler{
		db:        db,
		uploadDir: uploadDir,
		maxSize:   maxSize,
	}
	if len(jwtSecrets) > 0 {
		handler.jwtSecret = jwtSecrets[0]
	}
	return handler
}

func (h *UploadHandler) SetJWTSecret(secret string) {
	h.jwtSecret = secret
}

// isAuthorizedForPrivateFile 检查请求是否有权访问私有待审核文件（管理员/超级管理员/文件上传者）
func (h *UploadHandler) isAuthorizedForPrivateFile(c *gin.Context, file models.File) bool {
	if role, exists := c.Get("role"); exists {
		if roleStr, ok := role.(string); ok && (roleStr == "admin" || roleStr == "super_admin") {
			return true
		}
	}
	if userIDVal, exists := c.Get("user_id"); exists {
		if uid, ok := userIDVal.(uint); ok && uid != 0 && uid == file.UploaderID {
			return true
		}
	}

	authHeader := c.GetHeader("Authorization")
	if authHeader == "" {
		if cookieToken, err := c.Cookie("jwt"); err == nil && cookieToken != "" {
			authHeader = "Bearer " + cookieToken
		}
	}
	if authHeader == "" {
		return false
	}
	tokenString := strings.TrimSpace(strings.TrimPrefix(authHeader, "Bearer "))
	if tokenString == "" {
		return false
	}

	claims := &middleware.Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (interface{}, error) {
		return []byte(h.jwtSecret), nil
	})
	if err != nil || !token.Valid {
		return false
	}

	if claims.Role == "admin" || claims.Role == "super_admin" {
		return true
	}
	if claims.UserID != 0 && claims.UserID == file.UploaderID {
		return true
	}
	return false
}

// ServePublic 提供公开图片原图/变体，以及授权管理员/上传者的待审核私有原图。
func (h *UploadHandler) ServePublic(c *gin.Context) {
	relative := strings.TrimPrefix(filepath.ToSlash(c.Param("filepath")), "/")
	if relative == "" || strings.Contains(relative, "..") {
		servePublicNotFound(c)
		return
	}
	var file models.File
	variant, originalRelative, legacyVariant := imageVariantRequest(relative)
	originalPathCandidates := imageVariantSourcePathCandidates(originalRelative, variant != "")
	isPublic := true
	if err := h.db.Where("path IN ? AND access_scope = ?", originalPathCandidates, models.FileAccessPublic).First(&file).Error; err != nil {
		// 如果不是公开文件，尝试检查是否为私有待审核文件并校验管理员/上传者身份
		if privErr := h.db.Where("path IN ? AND access_scope = ?", originalPathCandidates, models.FileAccessPrivate).First(&file).Error; privErr != nil {
			servePublicNotFound(c)
			return
		}
		if !h.isAuthorizedForPrivateFile(c, file) {
			servePublicNotFound(c)
			return
		}
		isPublic = false
	}

	publicPath := file.Path
	mimeType := file.MimeType
	if variant != "" {
		expectedPath, ok := services.ImageVariantPath(file.Path, file.MimeType, variant)
		if !ok || (!legacyVariant && normalizeUploadPath(expectedPath) != normalizeUploadPath("/uploads/"+relative)) {
			servePublicNotFound(c)
			return
		}
		variantPath := strings.TrimPrefix(normalizeUploadPath(expectedPath), "/uploads/")
		var imageVariant models.ImageVariant
		if err := h.db.Where(
			"file_id = ? AND variant = ? AND recipe_version = ? AND status = ? AND path IN ?",
			file.ID,
			variant,
			services.ImageVariantRecipeVersion,
			models.ImageVariantStatusReady,
			uploadPathCandidates(variantPath),
		).First(&imageVariant).Error; err != nil {
			servePublicNotFound(c)
			return
		}
		publicPath = imageVariant.Path
		mimeType = imageVariant.MimeType
	}

	fullPath, err := services.ResolveUploadPath(h.uploadDir, publicPath)
	if err != nil {
		servePublicNotFound(c)
		return
	}
	if _, err := os.Stat(fullPath); err != nil {
		servePublicNotFound(c)
		return
	}
	c.Header("Content-Type", mimeType)
	if legacyVariant {
		// 旧版 App 会请求不带配方版本的缩略图。兼容响应禁止缓存，
		// 后续配方升级时客户端必须重新向当前版本解析，不能长期持有旧别名。
		c.Header("Cache-Control", "no-store")
	} else if isPublic {
		// 内容不可变（SHA256 路径）不代表访问权限不可变：access_scope 是数据库动态
		// 判断的，因此不能下发一年期 immutable。有界 TTL + SWR：消除每次浏览的
		// revalidate 往返，被撤回的公开文件最多 24 小时从浏览器过期；SWR 仅允许
		// 在 7 天内异步回源复验，撤回后不存在"缓存一年不可撤回"的问题。
		c.Header("Cache-Control", "public, max-age=86400, stale-while-revalidate=604800")
	} else {
		c.Header("Cache-Control", "private, no-store")
	}
	if uploadAccelRedirectEnabled() {
		c.Header("X-Accel-Redirect", uploadAccelRedirectPath(publicPath))
		c.Status(http.StatusOK)
		c.Writer.WriteHeaderNow()
		return
	}
	c.File(fullPath)
}

func servePublicNotFound(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusNotFound)
	c.Writer.WriteHeaderNow()
}

func uploadPathCandidates(publicPath string) []string {
	normalized := normalizeUploadPath(publicPath)
	if !strings.HasPrefix(normalized, "/uploads/") {
		normalized = "/uploads/" + strings.TrimPrefix(normalized, "/")
	}
	return []string{normalized, strings.TrimPrefix(normalized, "/")}
}

// imageVariantSourcePathCandidates 允许 GIF 静态预览使用 .jpg 变体路径，
// 同时仍能反查 .gif 原图。普通 JPEG/PNG 变体保持原有路径解析不变。
func imageVariantSourcePathCandidates(originalPath string, isVariant bool) []string {
	candidates := uploadPathCandidates(originalPath)
	if !isVariant || !strings.EqualFold(filepath.Ext(originalPath), ".jpg") {
		return candidates
	}

	gifPath := strings.TrimSuffix(originalPath, filepath.Ext(originalPath)) + ".gif"
	for _, candidate := range uploadPathCandidates(gifPath) {
		found := false
		for _, existing := range candidates {
			if existing == candidate {
				found = true
				break
			}
		}
		if !found {
			candidates = append(candidates, candidate)
		}
	}
	return candidates
}

func normalizeUploadPath(publicPath string) string {
	normalized := filepath.ToSlash(filepath.Clean(publicPath))
	if strings.HasPrefix(normalized, "uploads/") {
		return "/" + normalized
	}
	return normalized
}

func uploadAccelRedirectEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("UPLOAD_USE_ACCEL_REDIRECT"))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func uploadAccelRedirectPath(publicPath string) string {
	prefix := strings.TrimSpace(os.Getenv("UPLOAD_ACCEL_PREFIX"))
	if prefix == "" {
		prefix = "/_internal/uploads/"
	}
	if !strings.HasPrefix(prefix, "/") {
		prefix = "/" + prefix
	}
	prefix = strings.TrimSuffix(prefix, "/") + "/"
	relative := strings.TrimPrefix(normalizeUploadPath(publicPath), "/uploads/")
	return prefix + relative
}

func imageVariantRequest(relative string) (variant string, original string, legacy bool) {
	extension := filepath.Ext(relative)
	base := strings.TrimSuffix(relative, extension)
	for _, candidate := range []string{"thumb", "medium", "viewer"} {
		suffix := "_v1_" + candidate
		if strings.HasSuffix(base, suffix) {
			return candidate, strings.TrimSuffix(base, suffix) + extension, false
		}
		legacySuffix := "_" + candidate
		if strings.HasSuffix(base, legacySuffix) {
			return candidate, strings.TrimSuffix(base, legacySuffix) + extension, true
		}
	}
	return "", relative, false
}

// Upload 上传文件
func (h *UploadHandler) Upload(c *gin.Context) {
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请选择要上传的文件"})
		return
	}

	// 检查文件大小
	if file.Size > h.maxSize {
		c.JSON(http.StatusBadRequest, gin.H{"error": "文件大小不能超过10MB"})
		return
	}

	// 检查文件类型
	ext := strings.ToLower(filepath.Ext(file.Filename))
	if ext != ".jpg" && ext != ".jpeg" && ext != ".png" && ext != ".gif" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只支持 jpg/png/gif 格式"})
		return
	}

	// 打开文件
	src, err := file.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取文件失败"})
		return
	}
	defer src.Close()

	meta, err := validateImageFile(src)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	canonicalExt := canonicalImageExt(meta.MimeType)

	// 计算SHA256哈希
	hash := sha256.New()
	if _, err := io.Copy(hash, src); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "计算文件哈希失败"})
		return
	}
	hashStr := hex.EncodeToString(hash.Sum(nil))

	// 相同内容直接复用已有文件记录，避免违反 files.hash 唯一索引。
	var existing models.File
	err = h.db.Where("hash = ?", hashStr).First(&existing).Error
	if err == nil {
		// 确认磁盘文件仍然存在再复用，防止"数据库有记录但物理文件丢失"返回 404。
		diskPath, pathErr := services.ResolveUploadPath(h.uploadDir, existing.Path)
		if pathErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "文件路径记录非法"})
			return
		}
		if _, statErr := os.Stat(diskPath); statErr == nil {
			if err := h.grantFileToUser(existing.ID, c.GetUint("user_id")); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "记录文件所有权失败"})
				return
			}
			c.JSON(http.StatusOK, gin.H{
				"file_id": existing.ID,
				"url":     existing.Path,
				"hash":    existing.Hash,
				"reused":  true,
			})
			return
		}
		// 磁盘文件丢失 → 恢复到 existing.Path 指向的磁盘位置，保证所有历史引用与返回 URL 仍然有效。
		if _, err := src.Seek(0, io.SeekStart); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "读取文件失败"})
			return
		}
		if err := atomicWriteFile(diskPath, src); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复文件失败"})
			return
		}
		updates := map[string]interface{}{
			"size":      file.Size,
			"mime_type": meta.MimeType,
			"width":     meta.Width,
			"height":    meta.Height,
		}
		if err := h.db.Model(&existing).Updates(updates).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "更新文件记录失败"})
			return
		}
		if err := h.grantFileToUser(existing.ID, c.GetUint("user_id")); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "记录文件所有权失败"})
			return
		}
		c.JSON(http.StatusOK, gin.H{
			"file_id": existing.ID,
			"url":     existing.Path,
			"hash":    existing.Hash,
			"reused":  false,
		})
		return
	}
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "查询文件记录失败",
		})
		return
	}

	// 保存新文件（使用规范化扩展名，与真实内容一致）
	dir1 := filepath.Join(h.uploadDir, hashStr[:2])
	dstPath := filepath.Join(dir1, hashStr+canonicalExt)
	if _, err := src.Seek(0, io.SeekStart); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取文件失败"})
		return
	}
	if err := atomicWriteFile(dstPath, src); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败"})
		return
	}

	// 创建文件记录
	fileRecord := models.File{
		Hash:        hashStr,
		Path:        "/uploads/" + hashStr[:2] + "/" + hashStr + canonicalExt,
		Size:        file.Size,
		MimeType:    meta.MimeType,
		Width:       meta.Width,
		Height:      meta.Height,
		RefCount:    1,
		UploaderID:  c.GetUint("user_id"),
		Status:      "temporary",
		AccessScope: models.FileAccessPrivate,
	}

	if err := h.createOrGetFile(&fileRecord); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建文件记录失败"})
		return
	}
	if err := h.grantFileToUser(fileRecord.ID, c.GetUint("user_id")); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录文件所有权失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"file_id": fileRecord.ID,
		"url":     fileRecord.Path,
		"hash":    hashStr,
	})
}

// UploadMultiple 批量上传
func (h *UploadHandler) UploadMultiple(c *gin.Context) {
	form, err := c.MultipartForm()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "上传失败"})
		return
	}

	files := form.File["files"]
	if len(files) > 9 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "最多上传9个文件"})
		return
	}

	results := make([]gin.H, 0, len(files))
	createdFiles := make([]models.File, 0, len(files))

	for _, file := range files {
		// 检查文件大小
		if file.Size > h.maxSize {
			results = append(results, gin.H{
				"error": "文件大小超过限制: " + file.Filename,
			})
			continue
		}

		// 检查文件类型
		ext := strings.ToLower(filepath.Ext(file.Filename))
		if ext != ".jpg" && ext != ".jpeg" && ext != ".png" && ext != ".gif" {
			results = append(results, gin.H{
				"error": "不支持的格式: " + file.Filename,
			})
			continue
		}

		// 计算哈希
		src, err := file.Open()
		if err != nil {
			results = append(results, gin.H{"error": "读取文件失败: " + file.Filename})
			continue
		}

		meta, err := validateImageFile(src)
		if err != nil {
			src.Close()
			results = append(results, gin.H{"error": err.Error() + ": " + file.Filename})
			continue
		}
		canonicalExt := canonicalImageExt(meta.MimeType)

		hash := sha256.New()
		io.Copy(hash, src)
		src.Close()
		hashStr := hex.EncodeToString(hash.Sum(nil))

		// 相同内容直接复用已有文件记录，跳过磁盘写入
		var existing models.File
		if err := h.db.Where("hash = ?", hashStr).First(&existing).Error; err == nil {
			diskPath, pathErr := services.ResolveUploadPath(h.uploadDir, existing.Path)
			if pathErr != nil {
				continue
			}
			if _, statErr := os.Stat(diskPath); statErr == nil {
				if err := h.grantFileToUser(existing.ID, c.GetUint("user_id")); err != nil {
					c.JSON(http.StatusInternalServerError, gin.H{"error": "记录文件所有权失败"})
					return
				}
				results = append(results, gin.H{
					"file_id": existing.ID,
					"url":     existing.Path,
					"hash":    existing.Hash,
					"reused":  true,
				})
				createdFiles = append(createdFiles, existing)
				continue
			}
			// 磁盘文件丢失 → 恢复到 existing.Path 指向的磁盘位置
			err = func() error {
				src2, err := file.Open()
				if err != nil {
					return fmt.Errorf("恢复文件时读取失败")
				}
				defer src2.Close()
				return atomicWriteFile(diskPath, src2)
			}()
			if err != nil {
				results = append(results, gin.H{"error": err.Error()})
				continue
			}
			updates := map[string]interface{}{
				"size":      file.Size,
				"mime_type": meta.MimeType,
				"width":     meta.Width,
				"height":    meta.Height,
			}
			if err := h.db.Model(&existing).Updates(updates).Error; err != nil {
				results = append(results, gin.H{"error": "更新文件记录失败"})
				continue
			}
			if err := h.grantFileToUser(existing.ID, c.GetUint("user_id")); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "记录文件所有权失败"})
				return
			}
			results = append(results, gin.H{
				"file_id": existing.ID,
				"url":     existing.Path,
				"hash":    existing.Hash,
				"reused":  false,
			})
			createdFiles = append(createdFiles, existing)
			continue
		}

		// 保存新文件（使用规范化扩展名，与真实内容一致）
		dir1 := filepath.Join(h.uploadDir, hashStr[:2])
		dstPath := filepath.Join(dir1, hashStr+canonicalExt)
		err = func() error {
			src2, err := file.Open()
			if err != nil {
				return fmt.Errorf("保存文件时读取失败")
			}
			defer src2.Close()
			return atomicWriteFile(dstPath, src2)
		}()

		if err != nil {
			results = append(results, gin.H{"error": err.Error()})
			continue
		}

		// 创建文件记录
		fileRecord := models.File{
			Hash:        hashStr,
			Path:        "/uploads/" + hashStr[:2] + "/" + hashStr + canonicalExt,
			Size:        file.Size,
			MimeType:    meta.MimeType,
			Width:       meta.Width,
			Height:      meta.Height,
			RefCount:    1,
			UploaderID:  c.GetUint("user_id"),
			Status:      "temporary",
			AccessScope: models.FileAccessPrivate,
		}
		if err := h.createOrGetFile(&fileRecord); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
			return
		}
		if err := h.grantFileToUser(fileRecord.ID, c.GetUint("user_id")); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "记录文件所有权失败"})
			return
		}
		createdFiles = append(createdFiles, fileRecord)

		results = append(results, gin.H{
			"file_id": fileRecord.ID,
			"url":     fileRecord.Path,
			"hash":    hashStr,
		})
	}

	c.JSON(http.StatusOK, gin.H{
		"results": results,
		"total":   len(createdFiles),
	})
}

// createOrGetFile 创建文件记录；hash 冲突时返回已有记录（并发安全）
func (h *UploadHandler) createOrGetFile(fileRecord *models.File) error {
	if err := h.db.Clauses(clause.OnConflict{
		Columns:   []clause.Column{{Name: "hash"}},
		DoNothing: true,
	}).Create(fileRecord).Error; err != nil {
		return err
	}

	// ON CONFLICT DO NOTHING 时重新查询实际记录
	return h.db.Where("hash = ?", fileRecord.Hash).First(fileRecord).Error
}

func (h *UploadHandler) grantFileToUser(fileID, userID uint) error {
	if userID == 0 {
		return fmt.Errorf("缺少上传用户")
	}
	return h.db.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.FileUploadGrant{
		FileID: fileID,
		UserID: userID,
	}).Error
}
