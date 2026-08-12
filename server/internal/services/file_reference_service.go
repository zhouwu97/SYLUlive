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
	now := time.Now()
	return tx.Model(&models.File{}).Where("id IN ?", fileIDs).Updates(map[string]interface{}{
		"status":       "active",
		"claimed_at":   &now,
		"access_scope": models.FileAccessPublic,
	}).Error
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
