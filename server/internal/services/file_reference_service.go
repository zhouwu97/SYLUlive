package services

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

var ErrInvalidImageFileReference = errors.New("invalid image file reference")

// ParseImageFileIDs 严格解析客户端提交的图片 ID，不接受部分成功。
func ParseImageFileIDs(raw string) ([]uint, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return []uint{}, nil
	}
	parts := strings.Split(raw, ",")
	ids := make([]uint, 0, len(parts))
	for _, part := range parts {
		value, err := strconv.ParseUint(strings.TrimSpace(part), 10, 64)
		if err != nil || value == 0 {
			return nil, fmt.Errorf("%w: 图片 ID 格式错误", ErrInvalidImageFileReference)
		}
		ids = append(ids, uint(value))
	}
	return ids, nil
}

// ValidateImageFileIDs 校验图片记录与磁盘文件完整性，并保持调用方给定的顺序。
func ValidateImageFileIDs(tx *gorm.DB, fileIDs []uint, maxCount int, ownerIDs ...uint) ([]models.File, error) {
	if maxCount <= 0 || len(fileIDs) > maxCount {
		return nil, fmt.Errorf("%w: 图片数量不能超过 %d 张", ErrInvalidImageFileReference, maxCount)
	}
	if len(fileIDs) == 0 {
		return []models.File{}, nil
	}

	seen := make(map[uint]struct{}, len(fileIDs))
	for _, id := range fileIDs {
		if id == 0 {
			return nil, fmt.Errorf("%w: 图片 ID 不能为 0", ErrInvalidImageFileReference)
		}
		if _, exists := seen[id]; exists {
			return nil, fmt.Errorf("%w: 图片 ID %d 重复", ErrInvalidImageFileReference, id)
		}
		seen[id] = struct{}{}
	}

	var files []models.File
	if err := tx.Where("id IN ?", fileIDs).Find(&files).Error; err != nil {
		return nil, err
	}
	if len(files) != len(fileIDs) {
		return nil, fmt.Errorf("%w: 图片记录不存在", ErrInvalidImageFileReference)
	}
	byID := make(map[uint]models.File, len(files))
	for _, file := range files {
		byID[file.ID] = file
	}

	ordered := make([]models.File, 0, len(fileIDs))
	for _, id := range fileIDs {
		file := byID[id]
		if len(ownerIDs) > 0 && ownerIDs[0] != 0 && file.UploaderID != 0 {
			var grants int64
			if err := tx.Model(&models.FileUploadGrant{}).Where("file_id = ? AND user_id = ?", id, ownerIDs[0]).Count(&grants).Error; err != nil {
				return nil, err
			}
			if grants == 0 {
				return nil, fmt.Errorf("%w: 无权引用文件 %d", ErrInvalidImageFileReference, id)
			}
		}
		if !strings.HasPrefix(strings.ToLower(file.MimeType), "image/") {
			return nil, fmt.Errorf("%w: 文件 %d 不是图片", ErrInvalidImageFileReference, id)
		}
		path, err := imageDiskPath(file.Path)
		if err != nil {
			return nil, fmt.Errorf("%w: 文件 %d 路径非法", ErrInvalidImageFileReference, id)
		}
		info, err := os.Stat(path)
		if err != nil || info.IsDir() {
			return nil, fmt.Errorf("%w: 文件 %d 不存在", ErrInvalidImageFileReference, id)
		}
		ordered = append(ordered, file)
	}
	if len(ownerIDs) > 0 && ownerIDs[0] != 0 {
		now := time.Now()
		if err := tx.Model(&models.File{}).Where("id IN ?", fileIDs).Updates(map[string]interface{}{
			"status": "active", "claimed_at": &now,
		}).Error; err != nil {
			return nil, err
		}
	}
	return ordered, nil
}

func imageDiskPath(publicPath string) (string, error) {
	clean := filepath.ToSlash(filepath.Clean(strings.TrimSpace(publicPath)))
	if !strings.HasPrefix(clean, "/uploads/") && !strings.HasPrefix(clean, "uploads/") {
		return "", ErrInvalidImageFileReference
	}
	relative := strings.TrimPrefix(strings.TrimPrefix(clean, "/"), "uploads/")
	if relative == "" || relative == "." || strings.HasPrefix(relative, "../") {
		return "", ErrInvalidImageFileReference
	}
	uploadDir := strings.TrimSpace(os.Getenv("UPLOAD_DIR"))
	if uploadDir == "" {
		uploadDir = "uploads"
	}
	return filepath.Join(uploadDir, filepath.FromSlash(relative)), nil
}
