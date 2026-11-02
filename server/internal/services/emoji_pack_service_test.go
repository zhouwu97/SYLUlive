package services

import (
	"bytes"
	"context"
	"image"
	"image/color/palette"
	"image/gif"
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestEmojiPackImagePreflightLimitsAndCorruption(t *testing.T) {
	var large bytes.Buffer
	require.NoError(t, png.Encode(&large, image.NewRGBA(image.Rect(0, 0, 4097, 1))))
	_, err := ValidateEmojiPackImage(large.Bytes())
	require.Error(t, err)
	frame := image.NewPaletted(image.Rect(0, 0, 1, 1), palette.Plan9)
	for _, count := range []int{2, 501} {
		animation := &gif.GIF{}
		for i := 0; i < count; i++ {
			animation.Image = append(animation.Image, frame)
			animation.Delay = append(animation.Delay, 1)
		}
		var encoded bytes.Buffer
		require.NoError(t, gif.EncodeAll(&encoded, animation))
		normalized, err := ValidateEmojiPackImage(encoded.Bytes())
		if count == 2 {
			require.NoError(t, err)
			require.True(t, normalized.IsAnimated)
		} else {
			require.Error(t, err)
		}
		_, err = ValidateEmojiPackImage(encoded.Bytes()[:len(encoded.Bytes())-4])
		require.Error(t, err)
	}
	_, err = ValidateEmojiPackImage([]byte("<svg><script/></svg>"))
	require.Error(t, err)
}

func TestEmojiPackCleanupOnlyExpiredOrphans(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.CommunityEmojiPack{}, &models.CommunityEmojiPackAsset{}))
	sqlDB, _ := db.DB()
	t.Cleanup(func() { _ = sqlDB.Close() })
	s := NewEmojiPackService(db, t.TempDir())
	liveID := "community-00000000-0000-0000-0000-000000000001"
	orphanID := "community-00000000-0000-0000-0000-000000000002"
	for _, name := range []string{liveID, orphanID, ".stage-crashed", ".stage-active", "unrelated"} {
		dir := filepath.Join(s.root, name)
		require.NoError(t, os.MkdirAll(dir, 0700))
		if name != ".stage-active" {
			old := time.Now().Add(-25 * time.Hour)
			require.NoError(t, os.Chtimes(dir, old, old))
		}
	}
	require.NoError(t, db.Create(&models.CommunityEmojiPack{ID: liveID, UserID: 1, RequestKey: "live", Status: models.EmojiPackPending}).Error)
	require.NoError(t, s.CleanupOrphans(context.Background()))
	for _, name := range []string{liveID, ".stage-active", "unrelated"} {
		_, err := os.Stat(filepath.Join(s.root, name))
		require.NoError(t, err)
	}
	for _, name := range []string{orphanID, ".stage-crashed"} {
		_, err := os.Stat(filepath.Join(s.root, name))
		require.True(t, os.IsNotExist(err))
	}
}
