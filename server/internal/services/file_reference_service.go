package services

import (
	"errors"
	"fmt"
	"net/url"
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
		if len(ownerIDs) > 0 && ownerIDs[0] != 0 &&
			file.AccessScope != models.FileAccessPublic && file.UploaderID != ownerIDs[0] {
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
	return ordered, nil
}

// ClaimPublicImageFiles 在公开业务建立图片引用后，将文件升级为公开可读。
// 这一步必须由业务事务显式调用，不能由 ValidateImageFileIDs 的纯校验动作隐式完成。
func ClaimPublicImageFiles(tx *gorm.DB, fileIDs []uint) error {
	return claimPublicFiles(tx, fileIDs)
}

func claimPublicFiles(tx *gorm.DB, fileIDs []uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	return tx.Transaction(func(claimTx *gorm.DB) error {
		now := time.Now()
		if err := claimTx.Model(&models.File{}).Where("id IN ?", fileIDs).Updates(map[string]interface{}{
			"status":       "active",
			"claimed_at":   &now,
			"access_scope": models.FileAccessPublic,
		}).Error; err != nil {
			return err
		}
		return CreatePublicImageVariantTasks(claimTx, fileIDs)
	})
}

// ClaimPublicImagePaths 将直接保存 URL 的公开图片引用升级为 public。
// 兼容 /uploads、uploads 和历史 /api/uploads 三种路径形态，并忽略 URL 查询串。
// 外部图片 URL 不属于 files 表，保持 no-op。
func ClaimPublicImagePaths(tx *gorm.DB, publicPaths ...string) error {
	return claimPublicImagePathCandidates(tx, uploadReferenceCandidates(publicPaths...))
}

// ClaimPublicImagePathsForUser 仅允许文件上传者、被授权用户或已经公开的文件
// 升级为公开引用，避免任意用户提交已知路径把他人的私信附件公开化。
func ClaimPublicImagePathsForUser(tx *gorm.DB, userID uint, publicPaths ...string) error {
	paths := uploadReferenceCandidates(publicPaths...)
	if len(paths) == 0 {
		return nil
	}
	var files []models.File
	if err := tx.Where("path IN ?", paths).Find(&files).Error; err != nil {
		return err
	}
	ids := make([]uint, 0, len(files))
	for _, file := range files {
		if file.AccessScope != models.FileAccessPublic && file.UploaderID != userID {
			var grants int64
			if err := tx.Model(&models.FileUploadGrant{}).
				Where("file_id = ? AND user_id = ?", file.ID, userID).
				Count(&grants).Error; err != nil {
				return err
			}
			if grants == 0 {
				return fmt.Errorf("%w: 无权引用文件 %d", ErrInvalidImageFileReference, file.ID)
			}
		}
		ids = append(ids, file.ID)
	}
	return claimPublicFiles(tx, ids)
}

// FileIDsByPublicPaths 返回上传文件路径对应的 file_id，供编辑/审核删除旧引用时
// 做精确的权限回收。外部图片和无法解析的路径会被忽略。
func FileIDsByPublicPaths(tx *gorm.DB, publicPaths ...string) ([]uint, error) {
	paths := uploadReferenceCandidates(publicPaths...)
	if len(paths) == 0 {
		return []uint{}, nil
	}
	var files []models.File
	if err := tx.Select("id").Where("path IN ?", paths).Find(&files).Error; err != nil {
		return nil, err
	}
	ids := make([]uint, 0, len(files))
	for _, file := range files {
		ids = append(ids, file.ID)
	}
	return ids, nil
}

func claimPublicImagePathCandidates(tx *gorm.DB, paths []string) error {
	if len(paths) == 0 {
		return nil
	}
	var files []models.File
	if err := tx.Select("id").Where("path IN ?", paths).Find(&files).Error; err != nil {
		return err
	}
	ids := make([]uint, 0, len(files))
	for _, file := range files {
		ids = append(ids, file.ID)
	}
	return claimPublicFiles(tx, ids)
}

func uploadReferenceCandidates(publicPaths ...string) []string {
	pathSet := make(map[string]struct{}, len(publicPaths)*2)
	for _, raw := range publicPaths {
		path, ok := normalizeUploadReference(raw)
		if !ok {
			continue
		}
		pathSet[path] = struct{}{}
		if strings.HasPrefix(path, "/uploads/") {
			pathSet[strings.TrimPrefix(path, "/")] = struct{}{}
		} else {
			pathSet["/"+path] = struct{}{}
		}
	}
	if len(pathSet) == 0 {
		return nil
	}
	paths := make([]string, 0, len(pathSet))
	for path := range pathSet {
		paths = append(paths, path)
	}
	return paths
}

// ClaimPrivateFiles 在私有业务（如反馈附件）引用文件后激活文件，
// 但保持 access_scope=private，避免反馈截图暴露到公开 /uploads。
func ClaimPrivateFiles(tx *gorm.DB, fileIDs []uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	now := time.Now()
	return tx.Model(&models.File{}).Where("id IN ?", fileIDs).Updates(map[string]interface{}{
		"status":     "active",
		"claimed_at": &now,
	}).Error
}

// ClaimPrivateMessageFile 在私信引用附件后激活文件，但保持 private 访问范围。
func ClaimPrivateMessageFile(tx *gorm.DB, fileID uint) error {
	if fileID == 0 {
		return fmt.Errorf("%w: 文件 ID 不能为 0", ErrInvalidImageFileReference)
	}
	now := time.Now()
	result := tx.Model(&models.File{}).Where("id = ?", fileID).Updates(map[string]interface{}{
		"status":     "active",
		"claimed_at": &now,
	})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected != 1 {
		return fmt.Errorf("%w: 文件记录不存在", ErrInvalidImageFileReference)
	}
	return nil
}

// ResolveUploadPath 将 /uploads/ 下的数据库路径解析为磁盘路径，并拒绝路径穿越。
func ResolveUploadPath(uploadDir, publicPath string) (string, error) {
	clean := filepath.ToSlash(filepath.Clean(strings.TrimSpace(publicPath)))
	if !strings.HasPrefix(clean, "/uploads/") && !strings.HasPrefix(clean, "uploads/") {
		return "", ErrInvalidImageFileReference
	}
	relative := strings.TrimPrefix(strings.TrimPrefix(clean, "/"), "uploads/")
	if relative == "" || relative == "." || strings.HasPrefix(relative, "../") {
		return "", ErrInvalidImageFileReference
	}
	root := strings.TrimSpace(uploadDir)
	if root == "" {
		root = strings.TrimSpace(os.Getenv("UPLOAD_DIR"))
	}
	if root == "" {
		root = "uploads"
	}
	rootAbs, err := filepath.Abs(filepath.Clean(root))
	if err != nil {
		return "", err
	}
	fullAbs, err := filepath.Abs(filepath.Join(rootAbs, filepath.FromSlash(relative)))
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(rootAbs, fullAbs)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", ErrInvalidImageFileReference
	}
	return fullAbs, nil
}

func normalizeUploadReference(raw string) (string, bool) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", false
	}
	path := filepath.ToSlash(filepath.Clean(parsed.Path))
	path = strings.TrimPrefix(path, "/api")
	if !strings.HasPrefix(path, "/uploads/") && !strings.HasPrefix(path, "uploads/") {
		return "", false
	}
	if strings.HasPrefix(path, "uploads/") {
		path = "/" + path
	}
	return path, true
}

func imageDiskPath(publicPath string) (string, error) {
	return ResolveUploadPath("", publicPath)
}

// HasActivePublicReferences 检查指定 fileID 是否仍存在有效公开业务引用。
func HasActivePublicReferences(tx *gorm.DB, fileID uint, filePath string) (bool, error) {
	if fileID == 0 {
		return false, nil
	}
	// 1. 菜品实拍 (approved)
	if tx.Migrator().HasTable("canteen_dish_photos") {
		var dishPhotoCount int64
		if err := tx.Table("canteen_dish_photos").
			Where("file_id = ? AND status = ?", fileID, models.DishPhotoStatusApproved).
			Count(&dishPhotoCount).Error; err != nil {
			return false, err
		}
		if dishPhotoCount > 0 {
			return true, nil
		}
	}

	// 2. 帖子图片 (post_images join posts 有效状态)
	if tx.Migrator().HasTable("post_images") && tx.Migrator().HasTable("posts") {
		var postImageCount int64
		if err := tx.Table("post_images AS pi").
			Joins("JOIN posts p ON p.id = pi.post_id").
			Where("pi.file_id = ? AND p.status IN ?", fileID,
				[]models.PostStatus{
					models.PostStatusNormal,
					models.PostStatusSold,
					models.PostStatusClosed,
				}).
			Count(&postImageCount).Error; err != nil {
			return false, err
		}
		if postImageCount > 0 {
			return true, nil
		}
	}

	// 2b. 回复图片 (reply_images join replies 有效状态)
	if tx.Migrator().HasTable("reply_images") && tx.Migrator().HasTable("replies") {
		var replyImageCount int64
		if err := tx.Table("reply_images AS ri").
			Joins("JOIN replies r ON r.id = ri.reply_id").
			Where("ri.file_id = ? AND r.status = ?", fileID, models.ReplyStatusNormal).
			Count(&replyImageCount).Error; err != nil {
			return false, err
		}
		if replyImageCount > 0 {
			return true, nil
		}
	}

	// 3. 自定义表情资产
	if tx.Migrator().HasTable("user_emoji_assets") {
		var emojiCount int64
		if err := tx.Table("user_emoji_assets").Where("file_id = ?", fileID).Count(&emojiCount).Error; err != nil {
			return false, err
		}
		if emojiCount > 0 {
			return true, nil
		}
	}

	// 4. 路径引用（食堂封面、评价、头像等）
	if filePath != "" {
		cleanPath := strings.TrimPrefix(filePath, "/")
		if tx.Migrator().HasTable("canteens") {
			var canteenCount int64
			if err := tx.Table("canteens").Where("image = ? OR image = ?", filePath, "/"+cleanPath).Count(&canteenCount).Error; err != nil {
				return false, err
			}
			if canteenCount > 0 {
				return true, nil
			}
		}
		if tx.Migrator().HasTable("canteen_ratings") {
			var ratingCount int64
			if err := tx.Table("canteen_ratings").Where("(status = ? OR status IS NULL OR status = '') AND (images LIKE ? OR images LIKE ?)", models.ReviewEventStatusActive, "%"+filePath+"%", "%"+cleanPath+"%").Count(&ratingCount).Error; err != nil {
				return false, err
			}
			if ratingCount > 0 {
				return true, nil
			}
		}
		if tx.Migrator().HasTable("canteen_review_events") {
			var reviewCount int64
			if err := tx.Table("canteen_review_events").Where(
				"status = ? AND (images LIKE ? OR images LIKE ?)",
				models.ReviewEventStatusActive, "%"+filePath+"%", "%"+cleanPath+"%",
			).Count(&reviewCount).Error; err != nil {
				return false, err
			}
			if reviewCount > 0 {
				return true, nil
			}
		}
		if tx.Migrator().HasTable("users") {
			var userCount int64
			if err := tx.Table("users").Where("avatar = ? OR avatar = ? OR background = ? OR background = ?", filePath, "/"+cleanPath, filePath, "/"+cleanPath).Count(&userCount).Error; err != nil {
				return false, err
			}
			if userCount > 0 {
				return true, nil
			}
		}
		if tx.Migrator().HasTable("water_sections") {
			var sectionCount int64
			if err := tx.Table("water_sections").Where("avatar_url IN ? OR cover_url IN ? OR cover_portrait_url IN ? OR cover_landscape_url IN ? OR cover_square_url IN ?", []string{filePath, "/" + cleanPath}, []string{filePath, "/" + cleanPath}, []string{filePath, "/" + cleanPath}, []string{filePath, "/" + cleanPath}, []string{filePath, "/" + cleanPath}).Count(&sectionCount).Error; err != nil {
				return false, err
			}
			if sectionCount > 0 {
				return true, nil
			}
		}
	}

	return false, nil
}

// ReconcileFilePublicAccess 在公开业务引用移除后（如实拍下架、帖子删除等），
// 检查并回收不再被任何公开业务引用的文件权限，降级为 private。
func ReconcileFilePublicAccess(tx *gorm.DB, fileIDs ...uint) error {
	if len(fileIDs) == 0 {
		return nil
	}
	for _, id := range fileIDs {
		if id == 0 {
			continue
		}
		var file models.File
		if err := tx.Select("id", "path", "access_scope").First(&file, id).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				continue
			}
			return err
		}
		if file.AccessScope != models.FileAccessPublic {
			continue
		}
		hasPublic, err := HasActivePublicReferences(tx, file.ID, file.Path)
		if err != nil {
			return err
		}
		if !hasPublic {
			if err := tx.Model(&models.File{}).Where("id = ?", file.ID).Update("access_scope", models.FileAccessPrivate).Error; err != nil {
				return err
			}
		}
	}
	return nil
}
