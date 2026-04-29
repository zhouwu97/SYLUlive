package services

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

type FileService struct {
	db *gorm.DB
}

func NewFileService(db *gorm.DB) *FileService {
	return &FileService{db: db}
}

func (s *FileService) SaveFile(file *gin.Context, formName string) (*models.File, error) {
	f, err := file.FormFile(formName)
	if err != nil {
		return nil, err
	}

	src, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer src.Close()

	h := sha256.New()
	tmp := make([]byte, 32*1024)
	var totalSize int64 = 0
	for {
		n, err := src.Read(tmp)
		if err != nil && err != io.EOF {
			return nil, err
		}
		if n == 0 {
			break
		}
		h.Write(tmp[:n])
		totalSize += int64(n)
	}
	hash := hex.EncodeToString(h.Sum(nil))

	var existing models.File
	if err := s.db.Where("hash = ?", hash).First(&existing).Error; err == nil {
		existing.RefCount++
		s.db.Save(&existing)
		return &existing, nil
	}

	ext := filepath.Ext(f.Filename)
	filename := fmt.Sprintf("%d%s%s", time.Now().UnixNano(), GenerateRandomString(8), ext)
	path := filepath.Join("uploads", filename)

	if err := os.MkdirAll("uploads", 0755); err != nil {
		return nil, err
	}

	dst, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	defer dst.Close()

	src.Seek(0, 0)
	io.Copy(dst, src)

	newFile := models.File{
		Hash:     hash,
		Path:     path,
		Size:     totalSize,
		MimeType: f.Header.Get("Content-Type"),
		RefCount: 1,
	}

	if err := s.db.Create(&newFile).Error; err != nil {
		return nil, err
	}

	return &newFile, nil
}

func (s *FileService) DeleteFile(id uint) error {
	var file models.File
	if err := s.db.First(&file, id).Error; err != nil {
		return err
	}
	file.RefCount--
	if file.RefCount <= 0 {
		os.Remove(file.Path)
		return s.db.Delete(&file).Error
	}
	return s.db.Save(&file).Error
}

func (s *FileService) GetFile(id uint) (*models.File, error) {
	var file models.File
	if err := s.db.First(&file, id).Error; err != nil {
		return nil, err
	}
	return &file, nil
}

func GenerateRandomString(length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, length)
	for i := range b {
		b[i] = charset[i%len(charset)]
	}
	return string(b)
}
