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
	ImageVariantViewer        = "viewer"
)

// 变体长边上限，与 image_variant_worker.go 的 imageVariantRecipe 保持一致。
const (
	ImageVariantThumbMaxDimension  = 480
	ImageVariantMediumMaxDimension = 1280
	ImageVariantViewerMaxDimension = 2048
)

// ImageVariantPath 返回指定公开原图的版本化变体 URL。
func ImageVariantPath(filePath, mimeType, variant string) (string, bool) {
	if variant != ImageVariantThumb && variant != ImageVariantMedium && variant != ImageVariantViewer {
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
		// GIF 变体只保存静态首帧，统一以 JPEG 输出；原图路径仍保留 .gif。
		return ".jpg", true
	default:
		return "", false
	}
}

// imageVariantOutputMimeType 返回变体文件的真实 MIME。动态 GIF 的预览是
// JPEG 首帧，避免客户端在拿到静态预览时继续按动画 GIF 解码。
func imageVariantOutputMimeType(sourceMimeType string) (string, bool) {
	switch sourceMimeType {
	case "image/jpeg", "image/png":
		return sourceMimeType, true
	case "image/gif":
		return "image/jpeg", true
	default:
		return "", false
	}
}

// CreatePublicImageVariantTasks 在公开权限已经写入的同一事务中创建变体任务。
// GIF 原图保持动态内容，同时为 Feed/详情和查看器生成静态首帧预览任务。
func CreatePublicImageVariantTasks(tx *gorm.DB, fileIDs []uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	var files []models.File
	if err := tx.Where("id IN ? AND access_scope = ?", fileIDs, models.FileAccessPublic).Find(&files).Error; err != nil {
		return err
	}
	for _, file := range files {
		outputMimeType, ok := imageVariantOutputMimeType(file.MimeType)
		if !ok {
			continue
		}
		variants := []string{ImageVariantThumb, ImageVariantMedium}
		// viewer 档只服务大图全屏浏览：小图的 medium 已是原图尺寸，再生成 viewer 只会重复存储。
		// 宽高未知（历史数据 width/height=0）时保守跳过，等 backfill_image_metadata 补齐后自然覆盖。
		if longEdge := max(file.Width, file.Height); longEdge > ImageVariantMediumMaxDimension {
			variants = append(variants, ImageVariantViewer)
		}
		for _, variant := range variants {
			variantPath, ok := ImageVariantPath(file.Path, file.MimeType, variant)
			if !ok {
				continue
			}
			record := models.ImageVariant{
				FileID:        file.ID,
				Variant:       variant,
				RecipeVersion: ImageVariantRecipeVersion,
				Status:        models.ImageVariantStatusPending,
				Path:          variantPath,
				MimeType:      outputMimeType,
			}
			var existing models.ImageVariant
			query := tx.Where(
				"file_id = ? AND variant = ? AND recipe_version = ?",
				file.ID,
				variant,
				ImageVariantRecipeVersion,
			).Find(&existing)
			if query.Error != nil {
				return query.Error
			}
			if query.RowsAffected > 0 {
				// 旧版本曾把 GIF 记录为 unsupported 并使用 .gif 变体路径。
				// 现在 GIF 变体是 JPEG 静态首帧，启动回填时需要把这类旧记录
				// 重新排回 pending；ready 或 failed 记录仍保持幂等，不强制重跑。
				if file.MimeType == "image/gif" &&
					(existing.Status == models.ImageVariantStatusUnsupported ||
						existing.Path != record.Path || existing.MimeType != record.MimeType) {
					if err := tx.Model(&existing).Updates(map[string]interface{}{
						"status":          models.ImageVariantStatusPending,
						"path":            record.Path,
						"mime_type":       record.MimeType,
						"width":           0,
						"height":          0,
						"size":            0,
						"attempts":        0,
						"next_attempt_at": nil,
						"started_at":      nil,
						"last_error":      "",
					}).Error; err != nil {
						return err
					}
				}
				continue
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
