package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"shenliyuan/internal/models"

	"gorm.io/gorm"
)

const (
	MaxEmojiFavoriteCount = 80
	MaxEmojiQuotaBytes    = int64(50 * 1024 * 1024)
)

var (
	ErrEmojiFavoriteLimit    = errors.New("emoji favorite limit exceeded")
	ErrEmojiQuotaExceeded    = errors.New("emoji quota exceeded")
	ErrEmojiDuplicate        = errors.New("emoji favorite already exists")
	ErrEmojiMessageForbidden = errors.New("message emoji access forbidden")
)

// EmojiFavoriteView 是收藏接口返回的统一视图，同时携带用户配额快照。
type EmojiFavoriteView struct {
	ID                  uint                   `json:"id"`
	FavoriteID          uint                   `json:"favorite_id"`
	UserID              uint                   `json:"user_id"`
	Kind                string                 `json:"kind"`
	StickerID           *string                `json:"sticker_id,omitempty"`
	AssetID             *uint                  `json:"asset_id,omitempty"`
	SortOrder           int64                  `json:"sort_order"`
	Asset               *models.UserEmojiAsset `json:"asset,omitempty"`
	File                *models.File           `json:"file,omitempty"`
	QuotaUsedBytes      int64                  `json:"quota_used_bytes"`
	QuotaLimitBytes     int64                  `json:"quota_limit_bytes"`
	QuotaRemainingBytes int64                  `json:"quota_remaining_bytes"`
	FavoriteCount       int64                  `json:"favorite_count"`
	FavoriteLimit       int                    `json:"favorite_limit"`
}

type EmojiFavoriteService struct {
	db        *gorm.DB
	uploadDir string
}

func NewEmojiFavoriteService(db *gorm.DB, uploadDirs ...string) *EmojiFavoriteService {
	service := &EmojiFavoriteService{db: db}
	if len(uploadDirs) > 0 {
		service.uploadDir = strings.TrimSpace(uploadDirs[0])
	}
	return service
}

// List 返回用户的收藏，并为每一项填充相同的配额快照。
func (s *EmojiFavoriteService) List(ctx context.Context, userID uint) ([]EmojiFavoriteView, error) {
	if userID == 0 {
		return nil, errors.New("user id is required")
	}
	tx := s.db.WithContext(ctx)
	var favorites []models.UserEmojiFavorite
	if err := tx.Where("user_id = ?", userID).Order("sort_order ASC, id ASC").Find(&favorites).Error; err != nil {
		return nil, err
	}
	used, err := emojiQuotaUsed(tx, userID)
	if err != nil {
		return nil, err
	}
	var count int64
	if err := tx.Model(&models.UserEmojiFavorite{}).Where("user_id = ?", userID).Count(&count).Error; err != nil {
		return nil, err
	}
	views, err := s.buildViews(tx, favorites, used, count)
	if err != nil {
		return nil, err
	}
	return views, nil
}

// Quota 返回账号级表情包空间快照，供接口错误响应和管理端展示使用。
func (s *EmojiFavoriteService) Quota(ctx context.Context, userID uint) (int64, int64, error) {
	if userID == 0 {
		return 0, MaxEmojiQuotaBytes, errors.New("user id is required")
	}
	used, err := emojiQuotaUsed(s.db.WithContext(ctx), userID)
	return used, MaxEmojiQuotaBytes, err
}

func (s *EmojiFavoriteService) CreateBuiltin(ctx context.Context, userID uint, stickerID string) (*EmojiFavoriteView, error) {
	stickerID = strings.TrimSpace(stickerID)
	if userID == 0 || stickerID == "" {
		return nil, errors.New("user id and sticker id are required")
	}
	var result *EmojiFavoriteView
	err := s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var existing models.UserEmojiFavorite
		if err := tx.Where("user_id = ? AND kind = ? AND sticker_id = ?", userID, models.EmojiFavoriteKindBuiltin, stickerID).First(&existing).Error; err == nil {
			return ErrEmojiDuplicate
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		count, err := emojiFavoriteCount(tx, userID)
		if err != nil {
			return err
		}
		if count >= MaxEmojiFavoriteCount {
			return ErrEmojiFavoriteLimit
		}
		sortOrder, err := emojiNextSortOrder(tx, userID)
		if err != nil {
			return err
		}
		favorite := models.UserEmojiFavorite{UserID: userID, Kind: models.EmojiFavoriteKindBuiltin, StickerID: &stickerID, SortOrder: sortOrder}
		if err := tx.Create(&favorite).Error; err != nil {
			return err
		}
		used, err := emojiQuotaUsed(tx, userID)
		if err != nil {
			return err
		}
		result, err = s.buildView(tx, favorite, used, count+1)
		return err
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

func (s *EmojiFavoriteService) CreateCustom(ctx context.Context, userID, fileID uint) (*EmojiFavoriteView, error) {
	return s.createCustom(ctx, userID, fileID, false)
}

func (s *EmojiFavoriteService) createCustom(ctx context.Context, userID, fileID uint, messageAccess bool) (*EmojiFavoriteView, error) {
	if userID == 0 || fileID == 0 {
		return nil, errors.New("user id and file id are required")
	}
	var source models.File
	if err := s.db.WithContext(ctx).First(&source, fileID).Error; err != nil {
		return nil, err
	}
	if !messageAccess && !s.canReferenceFile(ctx, userID, source) {
		return nil, fmt.Errorf("%w: 无权引用文件", ErrInvalidImageFileReference)
	}
	if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(source.MimeType)), "image/") {
		return nil, fmt.Errorf("%w: 文件不是图片", ErrInvalidImageFileReference)
	}
	path, err := s.resolveUploadPath(source.Path)
	if err != nil {
		return nil, fmt.Errorf("%w: 文件路径非法", ErrInvalidImageFileReference)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%w: 文件不存在", ErrInvalidImageFileReference)
	}
	normalized, err := NormalizeEmoji(raw, strings.ToLower(strings.TrimSpace(strings.Split(source.MimeType, ";")[0])))
	if err != nil {
		return nil, err
	}
	hashBytes := sha256.Sum256(normalized.Bytes)
	hash := hex.EncodeToString(hashBytes[:])

	var result *EmojiFavoriteView
	var newPaths []string
	err = s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var duplicateCount int64
		if err := tx.Model(&models.UserEmojiAsset{}).
			Joins("JOIN files ON files.id = user_emoji_assets.file_id").
			Where("user_emoji_assets.user_id = ? AND files.hash = ?", userID, hash).
			Count(&duplicateCount).Error; err != nil {
			return err
		}
		if duplicateCount > 0 {
			return ErrEmojiDuplicate
		}
		count, err := emojiFavoriteCount(tx, userID)
		if err != nil {
			return err
		}
		if count >= MaxEmojiFavoriteCount {
			return ErrEmojiFavoriteLimit
		}
		sortOrder, err := emojiNextSortOrder(tx, userID)
		if err != nil {
			return err
		}
		used, err := emojiQuotaUsed(tx, userID)
		if err != nil {
			return err
		}
		if used+int64(len(normalized.Bytes)) > MaxEmojiQuotaBytes {
			return ErrEmojiQuotaExceeded
		}

		var assetFile models.File
		fileErr := tx.Where("hash = ?", hash).First(&assetFile).Error
		if errors.Is(fileErr, gorm.ErrRecordNotFound) {
			assetFile, newPaths, err = s.persistNormalizedFile(normalized, hash, userID)
			if err != nil {
				return err
			}
			if err := tx.Create(&assetFile).Error; err != nil {
				return err
			}
		} else if fileErr != nil {
			return fileErr
		} else {
			if err := tx.Model(&models.File{}).Where("id = ?", assetFile.ID).UpdateColumn("ref_count", gorm.Expr("COALESCE(ref_count, 0) + 1")).Error; err != nil {
				return err
			}
			assetFile.RefCount++
		}
		asset := models.UserEmojiAsset{UserID: userID, FileID: assetFile.ID, ThumbnailPath: s.thumbnailReference(hash), MimeType: normalized.MimeType, IsAnimated: normalized.IsAnimated, Width: normalized.Width, Height: normalized.Height}
		if err := tx.Create(&asset).Error; err != nil {
			return err
		}
		assetID := asset.ID
		favorite := models.UserEmojiFavorite{UserID: userID, Kind: models.EmojiFavoriteKindCustom, AssetID: &assetID, SortOrder: sortOrder}
		if err := tx.Create(&favorite).Error; err != nil {
			return err
		}
		result, err = s.buildView(tx, favorite, used+int64(len(normalized.Bytes)), count+1)
		return err
	})
	if err != nil {
		for _, path := range newPaths {
			_ = os.Remove(path)
		}
		return nil, err
	}
	return result, nil
}

func (s *EmojiFavoriteService) CreateFromMessage(ctx context.Context, userID, messageID uint) (*EmojiFavoriteView, error) {
	if userID == 0 || messageID == 0 {
		return nil, ErrEmojiMessageForbidden
	}
	var message models.Message
	if err := s.db.WithContext(ctx).First(&message, messageID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrEmojiMessageForbidden
		}
		return nil, err
	}
	var conversation models.Conversation
	if err := s.db.WithContext(ctx).First(&conversation, message.ConversationID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, ErrEmojiMessageForbidden
		}
		return nil, err
	}
	if conversation.User1ID != userID && conversation.User2ID != userID {
		return nil, ErrEmojiMessageForbidden
	}
	if message.FileID == nil || *message.FileID == 0 {
		return nil, ErrEmojiMessageForbidden
	}
	return s.createCustom(ctx, userID, *message.FileID, true)
}

func (s *EmojiFavoriteService) Delete(ctx context.Context, userID, favoriteID uint) error {
	if userID == 0 || favoriteID == 0 {
		return gorm.ErrRecordNotFound
	}
	return s.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var favorite models.UserEmojiFavorite
		if err := tx.Where("id = ? AND user_id = ?", favoriteID, userID).First(&favorite).Error; err != nil {
			return err
		}
		if err := tx.Delete(&favorite).Error; err != nil {
			return err
		}
		if favorite.Kind != models.EmojiFavoriteKindCustom || favorite.AssetID == nil {
			return nil
		}
		var asset models.UserEmojiAsset
		if err := tx.First(&asset, *favorite.AssetID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}
		var otherFavorites int64
		if err := tx.Model(&models.UserEmojiFavorite{}).Where("asset_id = ?", asset.ID).Count(&otherFavorites).Error; err != nil {
			return err
		}
		// 理论上同一资源通常只有一个收藏，但跨用户共享资源时不能删掉仍被引用的资产。
		if otherFavorites > 0 {
			return nil
		}
		if err := tx.Delete(&asset).Error; err != nil {
			return err
		}
		var otherAssets, messageRefs int64
		if err := tx.Model(&models.UserEmojiAsset{}).Where("file_id = ?", asset.FileID).Count(&otherAssets).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.Message{}).Where("file_id = ?", asset.FileID).Count(&messageRefs).Error; err != nil {
			return err
		}
		if err := tx.Model(&models.File{}).Where("id = ?", asset.FileID).UpdateColumn("ref_count", gorm.Expr("CASE WHEN COALESCE(ref_count, 0) > 0 THEN ref_count - 1 ELSE 0 END")).Error; err != nil {
			return err
		}
		if otherAssets == 0 && messageRefs == 0 {
			var file models.File
			if err := tx.First(&file, asset.FileID).Error; err == nil {
				if file.RefCount <= 1 {
					if err := tx.Delete(&file).Error; err != nil {
						return err
					}
					_ = os.Remove(s.resolveEmojiPath(file.Path))
					_ = os.Remove(s.resolveEmojiPath(asset.ThumbnailPath))
				}
			} else if !errors.Is(err, gorm.ErrRecordNotFound) {
				return err
			}
		}
		return nil
	})
}

// ResolveFavoriteAsset 校验收藏归属后返回受保护资源的磁盘路径和 MIME 类型。
func (s *EmojiFavoriteService) ResolveFavoriteAsset(ctx context.Context, userID, favoriteID uint, thumbnail bool) (string, string, error) {
	if userID == 0 || favoriteID == 0 {
		return "", "", gorm.ErrRecordNotFound
	}
	tx := s.db.WithContext(ctx)
	var favorite models.UserEmojiFavorite
	if err := tx.Where("id = ? AND user_id = ?", favoriteID, userID).First(&favorite).Error; err != nil {
		return "", "", err
	}
	if favorite.AssetID == nil {
		return "", "", gorm.ErrRecordNotFound
	}
	var asset models.UserEmojiAsset
	if err := tx.First(&asset, *favorite.AssetID).Error; err != nil {
		return "", "", err
	}
	path := asset.ThumbnailPath
	mimeType := asset.MimeType
	if !thumbnail {
		var file models.File
		if err := tx.First(&file, asset.FileID).Error; err != nil {
			return "", "", err
		}
		path = file.Path
		mimeType = file.MimeType
	}
	fullPath, err := s.resolveUploadPath(path)
	if err != nil {
		return "", "", gorm.ErrRecordNotFound
	}
	return fullPath, mimeType, nil
}

func (s *EmojiFavoriteService) canReferenceFile(ctx context.Context, userID uint, file models.File) bool {
	if file.AccessScope == models.FileAccessPublic || file.UploaderID == userID {
		return true
	}
	var count int64
	return s.db.WithContext(ctx).Model(&models.FileUploadGrant{}).Where("file_id = ? AND user_id = ?", file.ID, userID).Count(&count).Error == nil && count > 0
}

func (s *EmojiFavoriteService) persistNormalizedFile(normalized NormalizedEmoji, hash string, userID uint) (models.File, []string, error) {
	ext := ".jpg"
	if normalized.MimeType == "image/png" {
		ext = ".png"
	} else if normalized.MimeType == "image/gif" {
		ext = ".gif"
	}
	root := s.uploadDir
	if root == "" {
		root = strings.TrimSpace(os.Getenv("UPLOAD_DIR"))
	}
	if root == "" {
		root = "uploads"
	}
	assetDir := filepath.Join(root, "emoji")
	thumbDir := filepath.Join(root, "emoji-thumbnails")
	if err := os.MkdirAll(assetDir, 0o755); err != nil {
		return models.File{}, nil, err
	}
	if err := os.MkdirAll(thumbDir, 0o755); err != nil {
		return models.File{}, nil, err
	}
	assetPath := filepath.Join(assetDir, hash+ext)
	thumbPath := filepath.Join(thumbDir, hash+".png")
	if err := os.WriteFile(assetPath, normalized.Bytes, 0o600); err != nil {
		return models.File{}, nil, err
	}
	if err := os.WriteFile(thumbPath, normalized.Thumbnail, 0o600); err != nil {
		_ = os.Remove(assetPath)
		return models.File{}, nil, err
	}
	return models.File{Hash: hash, Path: filepath.ToSlash(filepath.Join("/uploads", "emoji", hash+ext)), Size: int64(len(normalized.Bytes)), MimeType: normalized.MimeType, UploaderID: userID, Status: "active", AccessScope: models.FileAccessPrivate, RefCount: 1}, []string{assetPath, thumbPath}, nil
}

func (s *EmojiFavoriteService) thumbnailReference(hash string) string {
	return filepath.ToSlash(filepath.Join("/uploads", "emoji-thumbnails", hash+".png"))
}

func (s *EmojiFavoriteService) buildViews(tx *gorm.DB, favorites []models.UserEmojiFavorite, used, count int64) ([]EmojiFavoriteView, error) {
	views := make([]EmojiFavoriteView, 0, len(favorites))
	for _, favorite := range favorites {
		view, err := s.buildView(tx, favorite, used, count)
		if err != nil {
			return nil, err
		}
		views = append(views, *view)
	}
	return views, nil
}

func (s *EmojiFavoriteService) buildView(tx *gorm.DB, favorite models.UserEmojiFavorite, used, count int64) (*EmojiFavoriteView, error) {
	view := &EmojiFavoriteView{ID: favorite.ID, FavoriteID: favorite.ID, UserID: favorite.UserID, Kind: favorite.Kind, StickerID: favorite.StickerID, AssetID: favorite.AssetID, SortOrder: favorite.SortOrder, QuotaUsedBytes: used, QuotaLimitBytes: MaxEmojiQuotaBytes, QuotaRemainingBytes: MaxEmojiQuotaBytes - used, FavoriteCount: count, FavoriteLimit: MaxEmojiFavoriteCount}
	if view.QuotaRemainingBytes < 0 {
		view.QuotaRemainingBytes = 0
	}
	if favorite.AssetID == nil {
		return view, nil
	}
	var asset models.UserEmojiAsset
	if err := tx.First(&asset, *favorite.AssetID).Error; err != nil {
		return nil, err
	}
	view.Asset = &asset
	var file models.File
	if err := tx.First(&file, asset.FileID).Error; err != nil {
		return nil, err
	}
	view.File = &file
	return view, nil
}

func emojiFavoriteCount(tx *gorm.DB, userID uint) (int64, error) {
	var count int64
	err := tx.Model(&models.UserEmojiFavorite{}).Where("user_id = ?", userID).Count(&count).Error
	return count, err
}

// emojiNextSortOrder 使用递减排序值，让最新收藏稳定出现在列表第一位。
func emojiNextSortOrder(tx *gorm.DB, userID uint) (int64, error) {
	var row struct {
		Minimum *int64 `gorm:"column:minimum"`
	}
	if err := tx.Model(&models.UserEmojiFavorite{}).
		Select("MIN(sort_order) AS minimum").
		Where("user_id = ?", userID).
		Scan(&row).Error; err != nil {
		return 0, err
	}
	if row.Minimum == nil {
		return 0, nil
	}
	return *row.Minimum - 1, nil
}

func emojiQuotaUsed(tx *gorm.DB, userID uint) (int64, error) {
	var used int64
	err := tx.Table("user_emoji_assets").Select("COALESCE(SUM(files.size), 0)").Joins("JOIN files ON files.id = user_emoji_assets.file_id").Where("user_emoji_assets.user_id = ?", userID).Scan(&used).Error
	return used, err
}

func (s *EmojiFavoriteService) resolveUploadPath(path string) (string, error) {
	return ResolveUploadPath(s.uploadDir, path)
}

func (s *EmojiFavoriteService) resolveEmojiPath(path string) string {
	resolved, err := s.resolveUploadPath(path)
	if err != nil {
		return ""
	}
	return resolved
}
