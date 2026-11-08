package services

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"shenliyuan/internal/models"
	"shenliyuan/internal/utils"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

const EmojiPackMaxUploadBytes int64 = 50 * 1024 * 1024
const EmojiPackMaxAssets = 100
const EmojiPackUserQuota int64 = 100 * 1024 * 1024
const EmojiPackMaxDecodedPixels int64 = 32 * 1024 * 1024

var (
	ErrEmojiPackInvalid   = errors.New("表情包参数无效")
	ErrEmojiPackConflict  = errors.New("状态已变化，请刷新后重试")
	ErrEmojiPackQuota     = errors.New("最多保留 5 份待审核投稿，账号投稿空间为 100 MB；请先撤回不需要的投稿")
	ErrEmojiPackForbidden = errors.New("没有操作此投稿的权限，不能审核自己的投稿")
)

var emojiPackIDPattern = regexp.MustCompile(`^community-[a-f0-9-]{36}$`)
var emojiPackKeyPattern = regexp.MustCompile(`^[a-zA-Z0-9_-]{16,64}$`)

type EmojiPackUploadImage struct {
	Name  string
	Bytes []byte
}

type EmojiPackSubmissionOptions struct {
	FamilyID   string
	CoverIndex int
	IconIndex  int
	Tags       []string
}

type EmojiPackService struct {
	DB   *gorm.DB
	root string
}

func NewEmojiPackService(db *gorm.DB, uploadDir string) *EmojiPackService {
	return &EmojiPackService{DB: db, root: filepath.Join(uploadDir, ".emoji-submissions")}
}

func emojiPackDigest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

// ValidateEmojiPackImage 在完整解码前核验尺寸与 GIF 总预算，避免小文件触发无界解码。
func ValidateEmojiPackImage(src []byte) (NormalizedEmoji, error) {
	if len(src) == 0 || int64(len(src)) > EmojiMaxCompressedBytes {
		return NormalizedEmoji{}, ErrEmojiPackInvalid
	}
	mime := http.DetectContentType(src)
	if mime != "image/png" && mime != "image/jpeg" && mime != "image/gif" {
		return NormalizedEmoji{}, ErrEmojiPackInvalid
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(src))
	if err != nil || config.Width < 1 || config.Height < 1 || config.Width > 4096 || config.Height > 4096 {
		return NormalizedEmoji{}, ErrEmojiPackInvalid
	}
	if mime == "image/gif" {
		if err := validateEmojiPackGIF(src, config.Width, config.Height); err != nil {
			return NormalizedEmoji{}, err
		}
		return normalizeEmojiPackGIF(src)
	}
	return NormalizeEmoji(src, mime)
}

func validateEmojiPackGIF(src []byte, width, height int) error {
	if len(src) < 13 {
		return ErrEmojiPackInvalid
	}
	offset := 13
	if src[10]&0x80 != 0 {
		offset += 3 * (1 << ((src[10] & 7) + 1))
	}
	frames := 0
	skipBlocks := func() bool {
		for offset < len(src) {
			size := int(src[offset])
			offset++
			if size == 0 {
				return true
			}
			offset += size
		}
		return false
	}
	for offset < len(src) {
		marker := src[offset]
		offset++
		switch marker {
		case 0x3b:
			if frames < 1 {
				return ErrEmojiPackInvalid
			}
			return nil
		case 0x21:
			offset++
			if !skipBlocks() {
				return ErrEmojiPackInvalid
			}
		case 0x2c:
			if offset+9 > len(src) {
				return ErrEmojiPackInvalid
			}
			frameWidth := int(binary.LittleEndian.Uint16(src[offset+4 : offset+6]))
			frameHeight := int(binary.LittleEndian.Uint16(src[offset+6 : offset+8]))
			packed := src[offset+8]
			offset += 9
			frames++
			if frameWidth < 1 || frameHeight < 1 || frameWidth > width || frameHeight > height || frames > 500 || int64(width)*int64(height)*int64(frames) > EmojiPackMaxDecodedPixels || (frames > 1 && (width > 2048 || height > 2048)) {
				return ErrEmojiPackInvalid
			}
			if packed&0x80 != 0 {
				offset += 3 * (1 << ((packed & 7) + 1))
			}
			offset++
			if !skipBlocks() {
				return ErrEmojiPackInvalid
			}
		default:
			return ErrEmojiPackInvalid
		}
	}
	return ErrEmojiPackInvalid
}

func (s *EmojiPackService) Submit(ctx context.Context, userID uint, key, name, description string, images []EmojiPackUploadImage, options ...EmojiPackSubmissionOptions) (*models.CommunityEmojiPack, error) {
	name, description = strings.TrimSpace(name), strings.TrimSpace(description)
	if userID == 0 || !emojiPackKeyPattern.MatchString(key) || name == "" || len(name) > 1200 || utils.CountGraphemes(name) > 40 || len(description) > 6000 || utils.CountGraphemes(description) > 300 || len(images) < 1 || len(images) > EmojiPackMaxAssets {
		return nil, ErrEmojiPackInvalid
	}
	option := EmojiPackSubmissionOptions{}
	if len(options) > 0 {
		option = options[0]
	}
	if option.CoverIndex < 0 || option.CoverIndex >= len(images) || option.IconIndex < 0 || option.IconIndex >= len(images) || len(option.Tags) > 5 || (option.FamilyID != "" && !emojiPackIDPattern.MatchString(option.FamilyID)) {
		return nil, ErrEmojiPackInvalid
	}
	for i, tag := range option.Tags {
		option.Tags[i] = strings.TrimSpace(tag)
		if option.Tags[i] == "" || len(option.Tags[i]) > 240 || utils.CountGraphemes(option.Tags[i]) > 12 {
			return nil, ErrEmojiPackInvalid
		}
	}
	if err := s.RequireCreator(ctx, userID); err != nil {
		return nil, err
	}
	// 摘要绑定请求原文和图片次序。相同幂等键不能覆盖已经审核的内容。
	hashInput := []string{name, description}
	optionBytes, _ := json.Marshal(option)
	hashInput = append(hashInput, string(optionBytes))
	var rawSize int64
	for _, item := range images {
		if len(item.Name) > 1200 || utils.CountGraphemes(item.Name) > 40 || strings.TrimSpace(item.Name) == "" {
			return nil, ErrEmojiPackInvalid
		}
		rawSize += int64(len(item.Bytes))
		if rawSize > EmojiPackMaxUploadBytes || int64(len(item.Bytes)) > EmojiMaxCompressedBytes {
			return nil, ErrEmojiPackInvalid
		}
		hashInput = append(hashInput, item.Name, emojiPackDigest(item.Bytes))
	}
	encoded, _ := json.Marshal(hashInput)
	contentHash := emojiPackDigest(encoded)
	var previous models.CommunityEmojiPack
	err := s.DB.WithContext(ctx).Where("user_id = ? AND request_key = ?", userID, key).First(&previous).Error
	if err == nil {
		if previous.ContentHash != contentHash {
			return nil, ErrEmojiPackConflict
		}
		return &previous, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}
	if err := os.MkdirAll(s.root, 0700); err != nil {
		return nil, err
	}
	stage, err := os.MkdirTemp(s.root, ".stage-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(stage)
	pack := models.CommunityEmojiPack{ID: "community-" + uuid.NewString(), UserID: userID, RequestKey: key, ContentHash: contentHash,
		Name: name, Description: description, Status: models.EmojiPackPending, Version: 1, MediaVersion: 1, CreatorRequired: true, Tags: option.Tags,
		CoverAssetID: fmt.Sprintf("image-%d", option.CoverIndex+1), IconAssetID: fmt.Sprintf("image-%d", option.IconIndex+1)}
	pack.FamilyID = pack.ID
	manifestAssets := make([]map[string]any, 0, len(images))
	for index, item := range images {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		normalized, err := ValidateEmojiPackImage(item.Bytes)
		if err != nil {
			return nil, fmt.Errorf("%w：第 %d 张图片无效或超限", ErrEmojiPackInvalid, index+1)
		}
		asset := models.CommunityEmojiPackAsset{PackID: pack.ID, AssetID: fmt.Sprintf("image-%d", index+1), Name: strings.TrimSpace(item.Name),
			SHA256: emojiPackDigest(normalized.Bytes), MimeType: normalized.MimeType, FileSize: len(normalized.Bytes), Width: normalized.Width, Height: normalized.Height, Animated: normalized.IsAnimated}
		asset.Name = strings.NewReplacer("\u2028", " ", "\u2029", " ").Replace(asset.Name)
		if err := os.WriteFile(filepath.Join(stage, asset.AssetID), normalized.Bytes, 0600); err != nil {
			return nil, err
		}
		thumbnail, err := emojiPackPreview(normalized.Bytes, 256)
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(filepath.Join(stage, asset.AssetID+".thumb"), thumbnail, 0600); err != nil {
			return nil, err
		}
		pack.StorageSize += int64(len(normalized.Bytes) + len(thumbnail))
		pack.Assets = append(pack.Assets, asset)
		pack.TotalSize += int64(asset.FileSize)
		entry := map[string]any{"id": asset.AssetID, "name": asset.Name, "path": "assets/" + asset.AssetID + emojiPackExt(asset.MimeType),
			"sha256": asset.SHA256, "mime_type": asset.MimeType, "file_size": asset.FileSize, "width": asset.Width, "height": asset.Height, "keywords": []string{}}
		if asset.Animated {
			entry["animated"] = true
		}
		manifestAssets = append(manifestAssets, entry)
	}
	if pack.TotalSize > EmojiPackMaxUploadBytes {
		return nil, ErrEmojiPackInvalid
	}
	pack.AssetCount = len(pack.Assets)
	for _, media := range []struct {
		id, name string
		size     int
	}{{pack.CoverAssetID, "cover.png", 320}, {pack.IconAssetID, "icon.png", 96}} {
		src, err := os.ReadFile(filepath.Join(stage, media.id))
		if err != nil {
			return nil, err
		}
		preview, err := emojiPackPreview(src, media.size)
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(filepath.Join(stage, media.name), preview, 0600); err != nil {
			return nil, err
		}
		pack.StorageSize += int64(len(preview))
	}
	destination := filepath.Join(s.root, pack.ID)
	if err := os.Rename(stage, destination); err != nil {
		return nil, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(destination)
		}
	}()
	err = s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&user, userID).Error; err != nil {
			return err
		}
		if user.AccountStatus != "active" && user.AccountStatus != "" {
			return ErrEmojiPackForbidden
		}
		if err := requireEmojiCreator(tx, userID, true); err != nil {
			return err
		}
		// 锁住账号后再次查幂等键，多个并行重试只能生成一份投稿。
		if err := tx.Where("user_id = ? AND request_key = ?", userID, key).First(&previous).Error; err == nil {
			if previous.ContentHash != contentHash {
				return ErrEmojiPackConflict
			}
			return nil
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		if option.FamilyID != "" {
			var root models.CommunityEmojiPack
			if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND user_id = ?", option.FamilyID, userID).First(&root).Error; err != nil {
				return err
			}
			if root.CatalogID() != root.ID || root.Status == models.EmojiPackWithdrawn {
				return ErrEmojiPackConflict
			}
			var revisions []models.CommunityEmojiPack
			if err := tx.Select("version", "status").Where("id = ? OR family_id = ?", root.ID, root.ID).Find(&revisions).Error; err != nil {
				return err
			}
			for _, revision := range revisions {
				if revision.Status == models.EmojiPackPending {
					return ErrEmojiPackConflict
				}
				if revision.Version >= pack.Version {
					pack.Version = revision.Version + 1
				}
			}
			pack.FamilyID = root.ID
		}
		pack.AuthorName = user.Nickname
		var pending int64
		if err := tx.Model(&models.CommunityEmojiPack{}).Where("user_id = ? AND status = ?", userID, models.EmojiPackPending).Count(&pending).Error; err != nil {
			return err
		}
		var usage struct{ Bytes int64 }
		if err := tx.Model(&models.CommunityEmojiPack{}).Select("COALESCE(SUM(CASE WHEN storage_size > 0 THEN storage_size ELSE total_size END), 0) AS bytes").Where("user_id = ? AND status <> ?", userID, models.EmojiPackWithdrawn).Scan(&usage).Error; err != nil {
			return err
		}
		if pending >= 5 || usage.Bytes+pack.StorageSize > EmojiPackUserQuota {
			return ErrEmojiPackQuota
		}
		var manifest bytes.Buffer
		encoder := json.NewEncoder(&manifest)
		encoder.SetEscapeHTML(false)
		if err := encoder.Encode(map[string]any{"schema_version": 1, "pack_id": pack.FamilyID, "version": pack.Version, "total_size": pack.TotalSize, "assets": manifestAssets}); err != nil {
			return err
		}
		pack.Manifest = bytes.TrimSuffix(manifest.Bytes(), []byte("\n"))
		pack.ManifestSHA256 = emojiPackDigest(pack.Manifest)
		return tx.Create(&pack).Error
	})
	if err != nil {
		return nil, err
	}
	if previous.ID != "" {
		return &previous, nil
	}
	committed = true
	return &pack, nil
}

func emojiPackExt(mime string) string {
	if mime == "image/png" {
		return ".png"
	}
	if mime == "image/gif" {
		return ".gif"
	}
	return ".jpg"
}

func (s *EmojiPackService) Review(ctx context.Context, id string, adminID uint, action, reason string) error {
	reason = strings.TrimSpace(reason)
	if !emojiPackIDPattern.MatchString(id) || utf8.RuneCountInString(reason) > 500 || utils.CountGraphemes(reason) > 300 || (action != "approve" && action != "reject" && action != "unpublish") || (action != "approve" && reason == "") {
		return ErrEmojiPackInvalid
	}
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var admin models.User
		if err := tx.Clauses(clause.Locking{Strength: "SHARE"}).First(&admin, adminID).Error; err != nil {
			return err
		}
		if (admin.AccountStatus != "active" && admin.AccountStatus != "") || (admin.Role != "admin" && admin.Role != "super_admin") {
			return ErrEmojiPackForbidden
		}
		var pack models.CommunityEmojiPack
		if err := tx.First(&pack, "id = ?", id).Error; err != nil {
			return err
		}
		if pack.UserID == adminID {
			return ErrEmojiPackForbidden
		}
		if action == "approve" && pack.CreatorRequired {
			if err := requireEmojiCreator(tx, pack.UserID, true); err != nil {
				return err
			}
		}
		var root models.CommunityEmojiPack
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&root, "id = ?", pack.CatalogID()).Error; err != nil {
			return err
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&pack, "id = ?", id).Error; err != nil {
			return err
		}
		expected, next := models.EmojiPackPending, models.EmojiPackPublished
		if action == "reject" {
			next = models.EmojiPackRejected
		}
		if action == "unpublish" {
			expected, next = models.EmojiPackPublished, models.EmojiPackUnpublished
		}
		if pack.Status != expected {
			return ErrEmojiPackConflict
		}
		family := tx.Model(&models.CommunityEmojiPack{}).Where("id = ? OR family_id = ?", pack.CatalogID(), pack.CatalogID())
		if action == "approve" {
			if err := family.Where("status = ?", models.EmojiPackPublished).Update("status", models.EmojiPackSuperseded).Error; err != nil {
				return err
			}
		}
		if action == "unpublish" {
			if err := family.Where("status = ?", models.EmojiPackSuperseded).Update("status", models.EmojiPackUnpublished).Error; err != nil {
				return err
			}
		}
		now := time.Now()
		result := tx.Model(&models.CommunityEmojiPack{}).Where("id = ? AND status = ?", id, expected).Updates(map[string]any{"status": next, "review_reason": reason, "reviewed_by": adminID, "reviewed_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return ErrEmojiPackConflict
		}
		actionName := map[string]string{"approve": "审核通过表情包", "reject": "驳回表情包", "unpublish": "下架表情包"}[action]
		return tx.Create(&models.AdminLog{AdminID: adminID, AdminName: admin.Nickname, Action: actionName, Target: id,
			Detail: reason}).Error
	})
}

func (s *EmojiPackService) Withdraw(ctx context.Context, id string, userID uint) error {
	if !emojiPackIDPattern.MatchString(id) {
		return gorm.ErrRecordNotFound
	}
	var removed []models.CommunityEmojiPack
	err := s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var pack models.CommunityEmojiPack
		if err := tx.Where("id = ? AND user_id = ?", id, userID).First(&pack).Error; err != nil {
			return err
		}
		var root models.CommunityEmojiPack
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&root, "id = ?", pack.CatalogID()).Error; err != nil {
			return err
		}
		if err := tx.First(&pack, "id = ?", id).Error; err != nil {
			return err
		}
		query := tx.Model(&models.CommunityEmojiPack{}).Where("id = ?", id)
		if pack.Status == models.EmojiPackPublished || pack.Status == models.EmojiPackSuperseded {
			query = tx.Model(&models.CommunityEmojiPack{}).Where("id = ? OR family_id = ?", pack.CatalogID(), pack.CatalogID())
		}
		if err := query.Update("status", models.EmojiPackWithdrawn).Error; err != nil {
			return err
		}
		if err := tx.Where("(id = ? OR family_id = ?) AND status = ?", pack.CatalogID(), pack.CatalogID(), models.EmojiPackWithdrawn).Find(&removed).Error; err != nil {
			return err
		}
		ids := make([]string, 0, len(removed))
		for _, item := range removed {
			ids = append(ids, item.ID)
		}
		return tx.Where("pack_id IN ?", ids).Delete(&models.CommunityEmojiPackAsset{}).Error
	})
	if err != nil {
		return err
	}
	for _, pack := range removed {
		if err := os.RemoveAll(filepath.Join(s.root, pack.ID)); err != nil {
			return err
		}
	}
	return nil
}

func (s *EmojiPackService) OpenAsset(ctx context.Context, id, assetID string) (*os.File, models.CommunityEmojiPackAsset, error) {
	var asset models.CommunityEmojiPackAsset
	if !emojiPackIDPattern.MatchString(id) {
		return nil, asset, gorm.ErrRecordNotFound
	}
	if err := s.DB.WithContext(ctx).Where("pack_id = ? AND asset_id = ?", id, assetID).First(&asset).Error; err != nil {
		return nil, asset, err
	}
	file, err := os.Open(filepath.Join(s.root, id, asset.AssetID))
	return file, asset, err
}

// CleanupOrphans 仅清理本功能生成且超过一天的孤儿目录；数据库不可用时停止清理。
func (s *EmojiPackService) CleanupOrphans(ctx context.Context) error {
	entries, err := os.ReadDir(s.root)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !entry.IsDir() || (!strings.HasPrefix(entry.Name(), ".stage-") && !emojiPackIDPattern.MatchString(entry.Name())) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if time.Since(info.ModTime()) < 24*time.Hour {
			continue
		}
		var count int64
		if err := s.DB.WithContext(ctx).Model(&models.CommunityEmojiPack{}).Where("id = ? AND status <> ?", entry.Name(), models.EmojiPackWithdrawn).Count(&count).Error; err != nil {
			return err
		}
		if count == 0 {
			if err := os.RemoveAll(filepath.Join(s.root, entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

// WithdrawEmojiPacksForUser 在注销事务中立即撤销公开访问，磁盘文件由受控维护清理。
func WithdrawEmojiPacksForUser(tx *gorm.DB, userID uint) error {
	if !tx.Migrator().HasTable(&models.CommunityEmojiPack{}) {
		return nil
	}
	if tx.Migrator().HasTable(&models.EmojiCreator{}) {
		if err := tx.Where("user_id = ?", userID).Delete(&models.EmojiCreator{}).Error; err != nil {
			return err
		}
	}
	ids := tx.Model(&models.CommunityEmojiPack{}).Select("id").Where("user_id = ?", userID)
	if err := tx.Where("pack_id IN (?)", ids).Delete(&models.CommunityEmojiPackAsset{}).Error; err != nil {
		return err
	}
	return tx.Model(&models.CommunityEmojiPack{}).Where("user_id = ?", userID).Update("status", models.EmojiPackWithdrawn).Error
}

func (s *EmojiPackService) Maintain(ctx context.Context) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.CleanupOrphans(ctx); err != nil {
				log.Printf("emoji pack maintenance unavailable: %v", err)
			}
		}
	}
}
