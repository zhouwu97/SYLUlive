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

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

// UploadCompetitionAwardEvidence 将证明材料直接写入私有目录，不生成公共 URL。
func (h *CompetitionHandler) UploadCompetitionAwardEvidence(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	fileHeader, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请选择要上传的证明材料"})
		return
	}
	if fileHeader.Size <= 0 || fileHeader.Size > h.maxEvidenceFileSize {
		c.JSON(http.StatusBadRequest, gin.H{"error": "证明材料大小不能超过10MB"})
		return
	}

	source, err := fileHeader.Open()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取证明材料失败"})
		return
	}
	defer source.Close()
	meta, err := validateImageFile(source)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	mimeType := meta.MimeType

	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(source, h.maxEvidenceFileSize+1))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "计算证明材料哈希失败"})
		return
	}
	if written > h.maxEvidenceFileSize {
		c.JSON(http.StatusBadRequest, gin.H{"error": "证明材料大小不能超过10MB"})
		return
	}
	hashValue := hex.EncodeToString(hasher.Sum(nil))

	var existing models.CompetitionAwardEvidenceFile
	err = h.db.Where("uploader_id = ? AND hash = ?", userID, hashValue).First(&existing).Error
	if err == nil && privateEvidenceFileExists(h.evidenceDir, existing.Path) {
		c.JSON(http.StatusOK, gin.H{"evidence_file_id": existing.ID, "reused": true})
		return
	}
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询证明材料失败"})
		return
	}

	extension := evidenceExtension(mimeType)
	relativePath := filepath.ToSlash(filepath.Join(fmt.Sprint(userID), hashValue[:2], hashValue+extension))
	fullPath, ok := privateEvidencePath(h.evidenceDir, relativePath)
	if !ok {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "证明材料路径无效"})
		return
	}
	if err := os.MkdirAll(filepath.Dir(fullPath), 0o700); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建证明材料目录失败"})
		return
	}
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取证明材料失败"})
		return
	}
	if err := writePrivateEvidenceFile(source, fullPath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存证明材料失败"})
		return
	}

	record := models.CompetitionAwardEvidenceFile{
		UploaderID: userID, Hash: hashValue, Path: relativePath,
		MimeType: mimeType, Size: written, Status: "temporary",
	}
	if err := h.db.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "uploader_id"}, {Name: "hash"}}, DoNothing: true,
	}).Create(&record).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "记录证明材料失败"})
		return
	}
	if err := h.db.Where("uploader_id = ? AND hash = ?", userID, hashValue).First(&record).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取证明材料记录失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"evidence_file_id": record.ID})
}

func evidenceExtension(mimeType string) string {
	switch mimeType {
	case "image/jpeg":
		return ".jpg"
	case "image/gif":
		return ".gif"
	default:
		return ".png"
	}
}

func writePrivateEvidenceFile(source io.Reader, destination string) error {
	temporary, err := os.CreateTemp(filepath.Dir(destination), ".evidence-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := io.Copy(temporary, source); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, destination); err != nil {
		if _, statErr := os.Stat(destination); statErr == nil {
			return nil
		}
		return err
	}
	return nil
}

func privateEvidencePath(root, relative string) (string, bool) {
	cleanRelative := filepath.Clean(filepath.FromSlash(relative))
	if cleanRelative == "." || filepath.IsAbs(cleanRelative) {
		return "", false
	}
	fullPath := filepath.Join(filepath.Clean(root), cleanRelative)
	resolved, err := filepath.Rel(filepath.Clean(root), fullPath)
	if err != nil || resolved == "." || strings.HasPrefix(resolved, "..") || filepath.IsAbs(resolved) {
		return "", false
	}
	return fullPath, true
}

func privateEvidenceFileExists(root, relative string) bool {
	path, ok := privateEvidencePath(root, relative)
	if !ok {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func serveCompetitionAwardEvidenceFile(c *gin.Context, root string, file models.CompetitionAwardEvidenceFile) {
	fullPath, ok := privateEvidencePath(root, file.Path)
	if !ok {
		c.JSON(http.StatusNotFound, gin.H{"error": "证明材料不存在"})
		return
	}
	if _, err := os.Stat(fullPath); err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "证明材料不存在"})
		return
	}
	c.Header("Content-Type", file.MimeType)
	c.Header("Cache-Control", "private, no-store")
	c.File(fullPath)
}
