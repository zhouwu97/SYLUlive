package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	xdraw "golang.org/x/image/draw"
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
}

// NewUploadHandler 创建上传处理器
func NewUploadHandler(uploadDir string, maxSize int64, db *gorm.DB) *UploadHandler {
	return &UploadHandler{
		db:        db,
		uploadDir: uploadDir,
		maxSize:   maxSize,
	}
}

// ServePublic 提供普通公开上传文件。内容哈希路径可安全使用长期缓存。
func (h *UploadHandler) ServePublic(c *gin.Context) {
	relative := strings.TrimPrefix(filepath.ToSlash(c.Param("filepath")), "/")
	if relative == "" || strings.Contains(relative, "..") {
		c.Status(http.StatusNotFound)
		c.Writer.WriteHeaderNow()
		return
	}
	path := "/uploads/" + relative
	var file models.File
	variant, originalRelative := imageVariantRequest(relative)
	if variant == "" {
		if err := h.db.Where("path = ? AND access_scope = ?", path, models.FileAccessPublic).First(&file).Error; err != nil {
			c.Status(http.StatusNotFound)
			c.Writer.WriteHeaderNow()
			return
		}
	} else {
		originalPath := "/uploads/" + originalRelative
		if err := h.db.Where("path = ? AND access_scope = ?", originalPath, models.FileAccessPublic).First(&file).Error; err != nil {
			c.Status(http.StatusNotFound)
			c.Writer.WriteHeaderNow()
			return
		}
	}
	fullPath, err := services.ResolveUploadPath(h.uploadDir, path)
	if err != nil {
		c.Status(http.StatusNotFound)
		c.Writer.WriteHeaderNow()
		return
	}
	if variant != "" {
		originalFullPath, err := services.ResolveUploadPath(h.uploadDir, "/uploads/"+originalRelative)
		if err != nil {
			c.Status(http.StatusNotFound)
			c.Writer.WriteHeaderNow()
			return
		}
		maxDimension := 480
		if variant == "medium" {
			maxDimension = 1280
		}
		if err := ensureImageVariant(
			originalFullPath,
			fullPath,
			file.MimeType,
			maxDimension,
		); err != nil {
			c.Status(http.StatusNotFound)
			c.Writer.WriteHeaderNow()
			return
		}
	}
	if _, err := os.Stat(fullPath); err != nil {
		c.Status(http.StatusNotFound)
		c.Writer.WriteHeaderNow()
		return
	}
	c.Header("Content-Type", file.MimeType)
	c.Header("Cache-Control", "public, max-age=31536000, immutable")
	c.File(fullPath)
}

func imageVariantRequest(relative string) (variant string, original string) {
	extension := filepath.Ext(relative)
	base := strings.TrimSuffix(relative, extension)
	for _, candidate := range []string{"thumb", "medium"} {
		suffix := "_" + candidate
		if strings.HasSuffix(base, suffix) {
			return candidate, strings.TrimSuffix(base, suffix) + extension
		}
	}
	return "", relative
}

func ensureImageVariant(
	originalPath string,
	variantPath string,
	mimeType string,
	maxDimension int,
) error {
	if _, err := os.Stat(variantPath); err == nil {
		return nil
	}
	source, err := os.Open(originalPath)
	if err != nil {
		return err
	}
	defer source.Close()
	decoded, _, err := image.Decode(source)
	if err != nil {
		return err
	}
	bounds := decoded.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width <= 0 || height <= 0 {
		return fmt.Errorf("图片尺寸无效")
	}
	targetWidth, targetHeight := width, height
	if width > maxDimension || height > maxDimension {
		scale := float64(maxDimension) / float64(max(width, height))
		targetWidth = max(1, int(float64(width)*scale))
		targetHeight = max(1, int(float64(height)*scale))
	}
	resized := image.NewRGBA(image.Rect(0, 0, targetWidth, targetHeight))
	xdraw.CatmullRom.Scale(
		resized,
		resized.Bounds(),
		decoded,
		bounds,
		xdraw.Over,
		nil,
	)

	if err := os.MkdirAll(filepath.Dir(variantPath), 0755); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(variantPath), ".image-variant-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	switch mimeType {
	case "image/jpeg":
		err = jpeg.Encode(temp, resized, &jpeg.Options{Quality: 82})
	case "image/png":
		err = png.Encode(temp, resized)
	case "image/gif":
		err = gif.Encode(temp, resized, &gif.Options{NumColors: 256})
	default:
		err = fmt.Errorf("不支持生成缩略图的格式: %s", mimeType)
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if _, statErr := os.Stat(variantPath); statErr == nil {
		return nil
	}
	return os.Rename(tempPath, variantPath)
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

