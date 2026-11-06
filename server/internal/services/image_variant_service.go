package services

import (
	"errors"
	"fmt"
	"path"
	"strings"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const (
	// JPEG/PNG 维持 v1；GIF 独立使用 v2，避免重建所有其他图片。
	ImageVariantRecipeVersion = models.ImageVariantRecipeVersion
	ImageVariantThumb         = "thumb"
	ImageVariantMedium        = "medium"
	ImageVariantViewer        = "viewer"
)

// 变体长边上限，与 image_variant_worker.go 的 imageVariantRecipe 保持一致。
const (
	// 上传与后台解码共用边界，防止历史文件绕过上传校验后耗尽解码内存。
	ImageMaxDimension = 12000
	ImageMaxPixels    = 50_000_000

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
	return fmt.Sprintf("%s_v%d_%s%s", base, models.ImageVariantRecipeVersionForMime(mimeType), variant, extension), true
}

// ReadyPublicImageVariantPath 只返回数据库已标记 ready 的公开图片变体。
// 预览接口使用该结果，避免把 pending/failed 任务路径提前暴露给客户端。
func ReadyPublicImageVariantPath(db *gorm.DB, publicPath, variant string) (string, bool, error) {
	candidates := uploadReferenceCandidates(publicPath)
	if db == nil || len(candidates) == 0 ||
		(variant != ImageVariantThumb && variant != ImageVariantMedium && variant != ImageVariantViewer) {
		return "", false, nil
	}
	// 旧部署可能尚未完成图片变体迁移；此时继续返回原图，不能把缺表当成接口故障。
	if !db.Migrator().HasTable(&models.File{}) || !db.Migrator().HasTable(&models.ImageVariant{}) {
		return "", false, nil
	}
	var file models.File
	if err := db.Where(
		"path IN ? AND access_scope = ?",
		candidates,
		models.FileAccessPublic,
	).First(&file).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return "", false, nil
		}
		return "", false, err
	}
	var imageVariant models.ImageVariant
	if err := db.Where(
		"file_id = ? AND variant = ? AND recipe_version = ? AND status = ?",
		file.ID,
		variant,
		models.ImageVariantRecipeVersionForMime(file.MimeType),
		models.ImageVariantStatusReady,
	).First(&imageVariant).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return "", false, nil
		}
		return "", false, err
	}
	if imageVariant.Path == "" {
		return "", false, nil
	}
	return imageVariant.Path, true, nil
}

func imageVariantExtension(mimeType string) (string, bool) {
	switch mimeType {
	case "image/jpeg":
		return ".jpg", true
	case "image/png":
		return ".png", true
	case "image/gif":
		// 静态预览使用 PNG，以保留 GIF 的透明区域。
		return ".png", true
	default:
		return "", false
	}
}

// imageVariantOutputMimeType 返回变体文件的真实 MIME。GIF 预览是静态 PNG。
func imageVariantOutputMimeType(sourceMimeType string) (string, bool) {
	switch sourceMimeType {
	case "image/jpeg", "image/png":
		return sourceMimeType, true
	case "image/gif":
		return "image/png", true
	default:
		return "", false
	}
}

// CreatePublicImageVariantTasks 在公开权限已经写入的同一事务中创建变体任务。
// GIF 原图保持动态内容，同时为 Feed/详情和查看器生成静态预览任务。
func CreatePublicImageVariantTasks(tx *gorm.DB, fileIDs []uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	var files []models.File
	if err := tx.Where("id IN ? AND access_scope = ?", fileIDs, models.FileAccessPublic).Find(&files).Error; err != nil {
		return err
	}
	for _, file := range files {
		recipeVersion := models.ImageVariantRecipeVersionForMime(file.MimeType)
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
				RecipeVersion: recipeVersion,
				Status:        models.ImageVariantStatusPending,
				Path:          variantPath,
				MimeType:      outputMimeType,
			}
			var existing models.ImageVariant
			query := tx.Where(
				"file_id = ? AND variant = ? AND recipe_version = ?",
				file.ID,
				variant,
				recipeVersion,
			).Find(&existing)
			if query.Error != nil {
				return query.Error
			}
			if query.RowsAffected > 0 {
				// 旧 worker 不认识 GIF v2 的 PNG MIME；若回滚时误领任务并耗尽
				// 重试，恢复新版后只重排这种特定错误，保留其他失败供排查。
				oldWorkerFailure := existing.Status == models.ImageVariantStatusFailed &&
					existing.NextAttemptAt == nil && existing.LastError == "原图/变体 MIME 与任务不一致"
				if file.MimeType == "image/gif" &&
					(existing.Status == models.ImageVariantStatusUnsupported ||
						existing.Path != record.Path || existing.MimeType != record.MimeType || oldWorkerFailure) {
					// 并发重排或 worker 领取后不能覆盖已变化的任务状态。
					if err := tx.Model(&models.ImageVariant{}).
						Where("id = ? AND status = ? AND attempts = ?", existing.ID, existing.Status, existing.Attempts).
						Updates(map[string]interface{}{
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
