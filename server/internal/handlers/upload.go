package handlers

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"shenliyuan/internal/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
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

	if err := h.db.Create(&fileRecord).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建文件记录失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"file_id": fileRecord.ID,
		"url":     fileRecord.Path,
		"hash":    hashStr,
	})
}

// RecoverUpload restores a missing /uploads file from a client-side cache copy.
// Unlike the normal upload endpoint, this writes to the requested legacy path,
// but only when the cached bytes match the SHA-256 hash embedded in that path.
func (h *UploadHandler) RecoverUpload(c *gin.Context) {
	if !recoveryAuthorized(c) {
		c.JSON(http.StatusForbidden, gin.H{"error": "recovery disabled"})
		return
	}

	expectedPath := path.Clean("/" + strings.TrimSpace(c.PostForm("expected_path")))
	if !strings.HasPrefix(expectedPath, "/uploads/") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "恢复路径无效"})
		return
	}

	relPath := strings.TrimPrefix(expectedPath, "/uploads/")
	if relPath == "" || strings.Contains(relPath, "..") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "恢复路径无效"})
		return
	}

	ext := strings.ToLower(filepath.Ext(relPath))
	if ext != ".jpg" && ext != ".jpeg" && ext != ".png" && ext != ".gif" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只支持 jpg/png/gif 格式"})
		return
	}

	expectedHash := strings.TrimSuffix(filepath.Base(relPath), ext)
	if len(expectedHash) != 64 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "恢复路径哈希无效"})
		return
	}

	var fileRecord models.File
	if err := h.db.Where("path = ?", expectedPath).First(&fileRecord).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusConflict, gin.H{"error": "数据库中不存在该文件路径"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询文件记录失败"})
		return
	}

	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请选择要恢复的文件"})
		return
	}
	if file.Size > h.maxSize {
		c.JSON(http.StatusBadRequest, gin.H{"error": "文件大小不能超过10MB"})
		return
	}

	dstPath := filepath.Join(h.uploadDir, filepath.FromSlash(relPath))
	uploadRoot, err := filepath.Abs(h.uploadDir)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复目录无效"})
		return
	}
	dstAbs, err := filepath.Abs(dstPath)
	if err != nil || (dstAbs != uploadRoot && !strings.HasPrefix(dstAbs, uploadRoot+string(os.PathSeparator))) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "恢复路径无效"})
		return
	}

	if _, err := os.Stat(dstAbs); err == nil {
		c.JSON(http.StatusOK, gin.H{"url": expectedPath, "already_exists": true})
		return
	} else if !os.IsNotExist(err) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查文件失败"})
		return
	}

	src, err := file.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取文件失败"})
		return
	}
	defer src.Close()

	if err := os.MkdirAll(filepath.Dir(dstAbs), 0755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建上传目录失败"})
		return
	}

	tmp, err := os.CreateTemp(filepath.Dir(dstAbs), ".recover-*")
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建临时文件失败"})
		return
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	hash := sha256.New()
	if _, err := io.Copy(tmp, io.TeeReader(src, hash)); err != nil {
		tmp.Close()
		c.JSON(http.StatusInternalServerError, gin.H{"error": "写入临时文件失败"})
		return
	}

	if err := tmp.Close(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "关闭临时文件失败"})
		return
	}

	hashStr := hex.EncodeToString(hash.Sum(nil))
	if !strings.EqualFold(hashStr, expectedHash) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缓存文件哈希与原路径不匹配"})
		return
	}

	if _, err := os.Stat(dstAbs); err == nil {
		c.JSON(http.StatusOK, gin.H{"url": expectedPath, "already_exists": true})
		return
	} else if !os.IsNotExist(err) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查文件失败"})
		return
	}

	if err := os.Rename(tmpPath, dstAbs); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复文件失败"})
		return
	}
	tmpPath = ""

	h.db.Model(&fileRecord).Updates(map[string]interface{}{
		"size":      file.Size,
		"mime_type": getMimeType(ext),
	})

	c.JSON(http.StatusOK, gin.H{
		"url":  expectedPath,
		"hash": hashStr,
	})
}

func recoveryAuthorized(c *gin.Context) bool {
	if expectedToken := os.Getenv("UPLOAD_RECOVERY_TOKEN"); expectedToken != "" {
		headerToken := c.GetHeader("X-Recovery-Token")
		if subtle.ConstantTimeCompare([]byte(headerToken), []byte(expectedToken)) == 1 {
			return true
		}
	}

	allowedUserID := os.Getenv("UPLOAD_RECOVERY_USER_ID")
	if allowedUserID == "" {
		return false
	}
	parsedUserID, err := strconv.ParseUint(allowedUserID, 10, 64)
	if err != nil {
		return false
	}
	return c.GetUint("user_id") == uint(parsedUserID)
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
		if err := h.db.Create(&fileRecord).Error; err != nil {
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
