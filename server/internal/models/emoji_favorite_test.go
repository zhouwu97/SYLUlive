package models

import (
	"testing"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func openEmojiTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("打开 SQLite 测试数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&UserEmojiAsset{}, &UserEmojiFavorite{}); err != nil {
		t.Fatalf("Emoji 模型迁移失败: %v", err)
	}
	return db
}

func TestEmojiFavoriteConstants(t *testing.T) {
	if EmojiFavoriteKindBuiltin != "builtin" || EmojiFavoriteKindCustom != "custom" {
		t.Fatalf("收藏类型常量错误: builtin=%q custom=%q", EmojiFavoriteKindBuiltin, EmojiFavoriteKindCustom)
	}
}

func TestUserEmojiAssetUniquePerUserFile(t *testing.T) {
	db := openEmojiTestDB(t)
	first := UserEmojiAsset{UserID: 1, FileID: 7, MimeType: "image/png", Width: 32, Height: 32}
	if err := db.Create(&first).Error; err != nil {
		t.Fatalf("创建 Emoji 资源失败: %v", err)
	}
	duplicate := UserEmojiAsset{UserID: 1, FileID: 7, MimeType: "image/png", Width: 32, Height: 32}
	if err := db.Create(&duplicate).Error; err == nil {
		t.Fatal("同一用户同一文件应拒绝重复资源")
	}
	otherUser := UserEmojiAsset{UserID: 2, FileID: 7, MimeType: "image/png", Width: 32, Height: 32}
	if err := db.Create(&otherUser).Error; err != nil {
		t.Fatalf("不同用户应可引用同一文件: %v", err)
	}
}

func TestUserEmojiFavoriteUniqueCustomAssetPerUser(t *testing.T) {
	db := openEmojiTestDB(t)
	assetID := uint(11)
	first := UserEmojiFavorite{UserID: 1, Kind: EmojiFavoriteKindCustom, AssetID: &assetID}
	if err := db.Create(&first).Error; err != nil {
		t.Fatalf("创建 custom 收藏失败: %v", err)
	}
	duplicate := UserEmojiFavorite{UserID: 1, Kind: EmojiFavoriteKindCustom, AssetID: &assetID}
	if err := db.Create(&duplicate).Error; err == nil {
		t.Fatal("同一用户同一 custom 资源应拒绝重复收藏")
	}
	otherUser := UserEmojiFavorite{UserID: 2, Kind: EmojiFavoriteKindCustom, AssetID: &assetID}
	if err := db.Create(&otherUser).Error; err != nil {
		t.Fatalf("不同用户应可收藏同一 custom 资源: %v", err)
	}
}

func TestUserEmojiFavoriteUniqueBuiltinStickerPerUser(t *testing.T) {
	db := openEmojiTestDB(t)
	stickerID := "wave"
	first := UserEmojiFavorite{UserID: 1, Kind: EmojiFavoriteKindBuiltin, StickerID: &stickerID}
	if err := db.Create(&first).Error; err != nil {
		t.Fatalf("创建 builtin 收藏失败: %v", err)
	}
	duplicate := UserEmojiFavorite{UserID: 1, Kind: EmojiFavoriteKindBuiltin, StickerID: &stickerID}
	if err := db.Create(&duplicate).Error; err == nil {
		t.Fatal("同一用户同一 builtin sticker 应拒绝重复收藏")
	}
}
