package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

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
		diskPath := filepath.Join(h.uploadDir, strings.TrimPrefix(existing.Path, "/uploads/"))
		if _, statErr := os.Stat(diskPath); statErr == nil {
			c.JSON(http.StatusOK, gin.H{
				"file_id": existing.ID,
				"url":     existing.Path,
				"hash":    existing.Hash,
				"reused":  true,
			})
			return
		}
		// 磁盘文件丢失 → 不返回旧记录，继续执行下面的保存逻辑用本次上传内容写回。
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{
			"error": "查询文件记录失败",
		})
		return
	}

	// 创建上传目录
	dir1 := filepath.Join(h.uploadDir, hashStr[:2])
	if err := os.MkdirAll(dir1, 0755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建上传目录失败"})
		return
	}

	// 保存文件
	dstPath := filepath.Join(dir1, hashStr+ext)
	dst, err := os.Create(dstPath)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建文件失败"})
		return
	}
	defer dst.Close()

	src.Seek(0, 0)
	if _, err := io.Copy(dst, src); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存文件失败"})
		return
	}

	// 创建文件记录
	fileRecord := models.File{
		Hash:     hashStr,
		Path:     "/uploads/" + hashStr[:2] + "/" + hashStr + ext,
		Size:     file.Size,
		MimeType: getMimeType(ext),
		RefCount: 1,
	}

	if err := h.createOrGetFile(&fileRecord); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建文件记录失败"})
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
		hash := sha256.New()
		io.Copy(hash, src)
		src.Close()
		hashStr := hex.EncodeToString(hash.Sum(nil))

		// 相同内容直接复用已有文件记录，跳过磁盘写入
		var existing models.File
		if err := h.db.Where("hash = ?", hashStr).First(&existing).Error; err == nil {
			diskPath := filepath.Join(h.uploadDir, strings.TrimPrefix(existing.Path, "/uploads/"))
			if _, statErr := os.Stat(diskPath); statErr == nil {
				results = append(results, gin.H{
					"file_id": existing.ID,
					"url":     existing.Path,
					"hash":    existing.Hash,
					"reused":  true,
				})
				createdFiles = append(createdFiles, existing)
				continue
			}
			// 磁盘文件丢失，继续执行后面的保存逻辑用本次上传内容写回。
		}

		// 创建上传目录
		dir1 := filepath.Join(h.uploadDir, hashStr[:2])
		if err := os.MkdirAll(dir1, 0755); err != nil {
			results = append(results, gin.H{"error": "创建目录失败"})
			continue
		}

		// 保存文件
		dstPath := filepath.Join(dir1, hashStr+ext)
		err = func() error {
			src2, err := file.Open()
			if err != nil {
				return fmt.Errorf("保存文件时读取失败")
			}
			defer src2.Close()

			dst, err := os.Create(dstPath)
			if err != nil {
				return fmt.Errorf("保存文件失败")
			}
			defer dst.Close()

			_, err = io.Copy(dst, src2)
			return err
		}()

		if err != nil {
			results = append(results, gin.H{"error": err.Error()})
			continue
		}

		// 创建文件记录
		fileRecord := models.File{
			Hash:     hashStr,
			Path:     "/uploads/" + hashStr[:2] + "/" + hashStr + ext,
			Size:     file.Size,
			MimeType: getMimeType(ext),
			RefCount: 1,
		}
		if err := h.createOrGetFile(&fileRecord); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "数据库操作失败"})
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

// getMimeType 根据扩展名获取MIME类型
func getMimeType(ext string) string {
	switch ext {
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	default:
		return "application/octet-stream"
	}
}
