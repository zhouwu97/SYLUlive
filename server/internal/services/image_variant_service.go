package services

import (
	"fmt"
	"path"
	"strings"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	// ImageVariantRecipeVersion 用于在调整缩放或编码配方时隔离新旧文件。
	ImageVariantRecipeVersion = 1
	ImageVariantThumb         = "thumb"
	ImageVariantMedium        = "medium"
)

// ImageVariantPath 返回指定公开原图的版本化变体 URL。
func ImageVariantPath(filePath, mimeType, variant string) (string, bool) {
	if variant != ImageVariantThumb && variant != ImageVariantMedium {
		return "", false
	}
	extension, ok := imageVariantExtension(mimeType)
	if !ok {
		return "", false
	}
	base := strings.TrimSuffix(filePath, path.Ext(filePath))
	if base == "" {
		return "", false
	}
	return fmt.Sprintf("%s_v%d_%s%s", base, ImageVariantRecipeVersion, variant, extension), true
}

func imageVariantExtension(mimeType string) (string, bool) {
	switch mimeType {
	case "image/jpeg":
		return ".jpg", true
	case "image/png":
		return ".png", true
	case "image/gif":
		return ".gif", true
	default:
		return "", false
	}
}

// CreatePublicImageVariantTasks 在公开权限已经写入的同一事务中创建变体任务。
// GIF 保持动态内容，只记录 unsupported，绝不生成静态首帧。
func CreatePublicImageVariantTasks(tx *gorm.DB, fileIDs []uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	var files []models.File
	if err := tx.Where("id IN ? AND access_scope = ?", fileIDs, models.FileAccessPublic).Find(&files).Error; err != nil {
		return err
	}
	for _, file := range files {
		status := models.ImageVariantStatusPending
		if file.MimeType == "image/gif" {
			status = models.ImageVariantStatusUnsupported
		} else if _, ok := imageVariantExtension(file.MimeType); !ok {
			continue
		}
		for _, variant := range []string{ImageVariantThumb, ImageVariantMedium} {
			variantPath, ok := ImageVariantPath(file.Path, file.MimeType, variant)
			if !ok {
				continue
			}
			record := models.ImageVariant{
				FileID:        file.ID,
				Variant:       variant,
				RecipeVersion: ImageVariantRecipeVersion,
				Status:        status,
				Path:          variantPath,
				MimeType:      file.MimeType,
			}
			if err := tx.Clauses(clause.OnConflict{
				Columns:   []clause.Column{{Name: "file_id"}, {Name: "variant"}, {Name: "recipe_version"}},
				DoNothing: true,
			}).Create(&record).Error; err != nil {
				return err
			}
		}
	}
	return nil
}

// BackfillPublicImageVariantTasks 为历史上已经公开且仍有有效引用的图片补建任务。
// 该操作幂等，可在开启 worker 前执行多次。
func BackfillPublicImageVariantTasks(tx *gorm.DB) error {
	var files []models.File
	if err := tx.Where("access_scope = ?", models.FileAccessPublic).Find(&files).Error; err != nil {
		return err
	}
	ids := make([]uint, 0, len(files))
	for _, file := range files {
		active, err := HasActivePublicReferences(tx, file.ID, file.Path)
		if err != nil {
			return err
		}
		if active {
			ids = append(ids, file.ID)
		}
	}
	return CreatePublicImageVariantTasks(tx, ids)
}
