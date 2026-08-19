package services

import (
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"shenliyuan/internal/models"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func newEmojiFavoriteServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	name := strings.NewReplacer("/", "_", "\\", "_").Replace(t.Name())
	db, err := gorm.Open(sqlite.Open("file:"+name+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}, &models.UserEmojiAsset{}, &models.UserEmojiFavorite{}, &models.Conversation{}, &models.Message{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func writeEmojiPNG(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			img.Set(x, y, color.RGBA{R: 255, A: 255})
		}
	}
	if err := png.Encode(file, img); err != nil {
		t.Fatal(err)
	}
	return path
}

func createEmojiSourceFile(t *testing.T, db *gorm.DB, dir string, userID uint) models.File {
	t.Helper()
	path := writeEmojiPNG(t, dir, "source.png")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	file := models.File{Hash: "source-" + t.Name(), Path: "/uploads/source.png", Size: info.Size(), MimeType: "image/png", UploaderID: userID, Status: "active", AccessScope: models.FileAccessPrivate, RefCount: 1}
	if err := db.Create(&file).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.FileUploadGrant{FileID: file.ID, UserID: userID}).Error; err != nil {
		t.Fatal(err)
	}
	return file
}

func TestEmojiFavoriteServiceCreatesAndListsCustomFavorite(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	dir := t.TempDir()
	t.Setenv("UPLOAD_DIR", dir)
	source := createEmojiSourceFile(t, db, dir, 7)
	service := NewEmojiFavoriteService(db)

	created, err := service.CreateCustom(context.Background(), 7, source.ID)
	if err != nil {
		t.Fatalf("创建自定义表情失败: %v", err)
	}
	if created.Kind != models.EmojiFavoriteKindCustom || created.AssetID == nil {
		t.Fatalf("返回的收藏视图错误: %+v", created)
	}
	if created.QuotaLimitBytes != MaxEmojiQuotaBytes || created.FavoriteLimit != MaxEmojiFavoriteCount {
		t.Fatalf("配额字段错误: %+v", created)
	}
	items, err := service.List(context.Background(), 7)
	if err != nil || len(items) != 1 || items[0].AssetID == nil {
		t.Fatalf("列出收藏错误: len=%d err=%v items=%+v", len(items), err, items)
	}
}

func TestEmojiFavoriteServiceCreatesBuiltinAndRejectsDuplicate(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	service := NewEmojiFavoriteService(db)
	created, err := service.CreateBuiltin(context.Background(), 7, "  builtin-heart  ")
	if err != nil {
		t.Fatalf("创建内置收藏失败: %v", err)
	}
	if created.Kind != models.EmojiFavoriteKindBuiltin || created.StickerID == nil || *created.StickerID != "builtin-heart" {
		t.Fatalf("内置收藏视图错误: %+v", created)
	}
	if _, err := service.CreateBuiltin(context.Background(), 7, "builtin-heart"); !errors.Is(err, ErrEmojiDuplicate) {
		t.Fatalf("预期内置表情重复错误，得到 %v", err)
	}
}

func TestEmojiFavoriteServiceRejectsDuplicateAndUnauthorizedSource(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	dir := t.TempDir()
	t.Setenv("UPLOAD_DIR", dir)
	source := createEmojiSourceFile(t, db, dir, 7)
	service := NewEmojiFavoriteService(db)
	if _, err := service.CreateCustom(context.Background(), 7, source.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateCustom(context.Background(), 7, source.ID); !errors.Is(err, ErrEmojiDuplicate) {
		t.Fatalf("预期重复收藏错误，得到 %v", err)
	}
	if _, err := service.CreateCustom(context.Background(), 8, source.ID); err == nil {
		t.Fatal("预期拒绝无权引用源文件")
	}
}

func TestEmojiFavoriteServiceEnforcesFavoriteLimitAndQuota(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	dir := t.TempDir()
	t.Setenv("UPLOAD_DIR", dir)
	source := createEmojiSourceFile(t, db, dir, 7)
	for i := 0; i < MaxEmojiFavoriteCount; i++ {
		sticker := "sticker-" + strings.Repeat("x", 2) + string(rune('a'+i%26)) + string(rune('0'+i/26))
		if err := db.Create(&models.UserEmojiFavorite{UserID: 7, Kind: models.EmojiFavoriteKindBuiltin, StickerID: &sticker, SortOrder: int64(i)}).Error; err != nil {
			t.Fatal(err)
		}
	}
	service := NewEmojiFavoriteService(db)
	if _, err := service.CreateCustom(context.Background(), 7, source.ID); !errors.Is(err, ErrEmojiFavoriteLimit) {
		t.Fatalf("预期收藏数量上限错误，得到 %v", err)
	}
	if err := db.Where("user_id = ?", 7).Delete(&models.UserEmojiFavorite{}).Error; err != nil {
		t.Fatal(err)
	}
	assetFile := models.File{Hash: "existing-emoji", Path: "/uploads/existing.png", Size: MaxEmojiQuotaBytes, MimeType: "image/png", UploaderID: 7, Status: "active", AccessScope: models.FileAccessPrivate, RefCount: 1}
	if err := db.Create(&assetFile).Error; err != nil {
		t.Fatal(err)
	}
	asset := models.UserEmojiAsset{UserID: 7, FileID: assetFile.ID, MimeType: assetFile.MimeType, Width: 8, Height: 8}
	if err := db.Create(&asset).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.UserEmojiFavorite{UserID: 7, Kind: models.EmojiFavoriteKindCustom, AssetID: &asset.ID}).Error; err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateCustom(context.Background(), 7, source.ID); !errors.Is(err, ErrEmojiQuotaExceeded) {
		t.Fatalf("预期配额上限错误，得到 %v", err)
	}
}

func TestEmojiFavoriteServiceCreateFromMessageRequiresParticipant(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	dir := t.TempDir()
	t.Setenv("UPLOAD_DIR", dir)
	source := createEmojiSourceFile(t, db, dir, 7)
	conversation := models.Conversation{User1ID: 7, User2ID: 8}
	if err := db.Create(&conversation).Error; err != nil {
		t.Fatal(err)
	}
	message := models.Message{ConversationID: conversation.ID, SenderID: 7, FileID: &source.ID}
	if err := db.Create(&message).Error; err != nil {
		t.Fatal(err)
	}
	service := NewEmojiFavoriteService(db)
	if _, err := service.CreateFromMessage(context.Background(), 9, message.ID); !errors.Is(err, ErrEmojiMessageForbidden) {
		t.Fatalf("预期拒绝非会话成员，得到 %v", err)
	}
	if _, err := service.CreateFromMessage(context.Background(), 8, message.ID); err != nil {
		t.Fatalf("会话参与者收藏消息图片失败: %v", err)
	}
}

func TestEmojiFavoriteServiceDeleteKeepsSharedFile(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	dir := t.TempDir()
	t.Setenv("UPLOAD_DIR", dir)
	source := createEmojiSourceFile(t, db, dir, 7)
	service := NewEmojiFavoriteService(db)
	created, err := service.CreateCustom(context.Background(), 7, source.ID)
	if err != nil {
		t.Fatal(err)
	}
	if created.File == nil {
		t.Fatal("自定义收藏缺少文件视图")
	}
	if err := db.Create(&models.Message{SenderID: 7, FileID: &created.File.ID}).Error; err != nil {
		t.Fatal(err)
	}
	if err := service.Delete(context.Background(), 7, created.ID); err != nil {
		t.Fatalf("删除收藏失败: %v", err)
	}
	var count int64
	if err := db.Model(&models.UserEmojiFavorite{}).Where("id = ?", created.ID).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("收藏记录未删除")
	}
	var kept models.File
	if err := db.First(&kept, created.File.ID).Error; err != nil {
		t.Fatalf("消息仍引用文件时不应清理文件: %v", err)
	}
}

func TestEmojiFavoriteServicePutsNewestFavoriteFirst(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	service := NewEmojiFavoriteService(db)
	if _, err := service.CreateBuiltin(context.Background(), 7, "sticker-old"); err != nil {
		t.Fatal(err)
	}
	if _, err := service.CreateBuiltin(context.Background(), 7, "sticker-new"); err != nil {
		t.Fatal(err)
	}
	items, err := service.List(context.Background(), 7)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || items[0].StickerID == nil || *items[0].StickerID != "sticker-new" {
		t.Fatalf("最新收藏未排在首位: %+v", items)
	}
}

func TestEmojiFavoriteServiceCreatesFromPublicImage(t *testing.T) {
	db := newEmojiFavoriteServiceTestDB(t)
	dir := t.TempDir()
	t.Setenv("UPLOAD_DIR", dir)
	source := createEmojiSourceFile(t, db, dir, 7)
	service := NewEmojiFavoriteService(db)

	created, err := service.CreateFromPublicImage(context.Background(), 8, source.Path)
	if err != nil {
		t.Fatalf("从公共图片创建自定义收藏失败: %v", err)
	}
	if created.Kind != models.EmojiFavoriteKindCustom || created.AssetID == nil {
		t.Fatalf("创建的公共图片表情视图错误: %+v", created)
	}
	items, err := service.List(context.Background(), 8)
	if err != nil || len(items) != 1 {
		t.Fatalf("列出公共图片收藏错误: len=%d err=%v", len(items), err)
	}
}

