package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func newEmojiFavoriteHandlerTest(t *testing.T, uploadDirs ...string) (*gin.Engine, *gorm.DB) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:emoji_handler_test?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}, &models.UserEmojiAsset{}, &models.UserEmojiFavorite{}))
	service := services.NewEmojiFavoriteService(db, uploadDirs...)
	handler := NewEmojiFavoriteHandler(service)
	r := gin.New()
	r.Use(func(c *gin.Context) {
		c.Set("user_id", uint(7))
		c.Next()
	})
	r.GET("/api/emoji/favorites", handler.List)
	r.DELETE("/api/emoji/favorites/:id", handler.Delete)
	return r, db
}

func TestEmojiFavoriteHandlerListIsUserScoped(t *testing.T) {
	r, db := newEmojiFavoriteHandlerTest(t)
	stickerA := "sticker-a"
	stickerB := "sticker-b"
	require.NoError(t, db.Create(&models.UserEmojiFavorite{UserID: 7, Kind: models.EmojiFavoriteKindBuiltin, StickerID: &stickerA}).Error)
	require.NoError(t, db.Create(&models.UserEmojiFavorite{UserID: 8, Kind: models.EmojiFavoriteKindBuiltin, StickerID: &stickerB}).Error)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/emoji/favorites", nil)
	r.ServeHTTP(response, request)
	require.Equal(t, http.StatusOK, response.Code)
	require.Contains(t, response.Body.String(), "sticker-a")
	require.NotContains(t, response.Body.String(), "sticker-b")
}

func TestEmojiFavoriteHandlerQuotaErrorIncludesUsageFields(t *testing.T) {
	r, db := newEmojiFavoriteHandlerTest(t)
	file := models.File{
		Hash:        "quota-file",
		Path:        "/uploads/quota.png",
		Size:        services.MaxEmojiQuotaBytes,
		MimeType:    "image/png",
		UploaderID:  7,
		Status:      "active",
		AccessScope: models.FileAccessPrivate,
	}
	require.NoError(t, db.Create(&file).Error)
	asset := models.UserEmojiAsset{UserID: 7, FileID: file.ID, MimeType: "image/png"}
	require.NoError(t, db.Create(&asset).Error)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/emoji/favorites/quota-error", nil)
	r.GET("/api/emoji/favorites/quota-error", func(c *gin.Context) {
		handler := NewEmojiFavoriteHandler(services.NewEmojiFavoriteService(db))
		handler.writeError(c, services.ErrEmojiQuotaExceeded)
	})
	r.ServeHTTP(response, request)

	require.Equal(t, http.StatusConflict, response.Code)
	var payload map[string]any
	require.NoError(t, json.Unmarshal(response.Body.Bytes(), &payload))
	require.Equal(t, "emoji_quota_exceeded", payload["code"])
	require.Equal(t, float64(services.MaxEmojiQuotaBytes), payload["quota_used"])
	require.Equal(t, float64(services.MaxEmojiQuotaBytes), payload["quota_limit"])
}

func TestEmojiFavoriteHandlerServeAssetIsOwnerScoped(t *testing.T) {
	uploadDir := t.TempDir()
	assetDir := filepath.Join(uploadDir, "emoji")
	thumbnailDir := filepath.Join(uploadDir, "emoji-thumbnails")
	require.NoError(t, os.MkdirAll(assetDir, 0o755))
	require.NoError(t, os.MkdirAll(thumbnailDir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(assetDir, "asset.png"), []byte("asset"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(thumbnailDir, "asset.png"), []byte("thumb"), 0o600))

	r, db := newEmojiFavoriteHandlerTest(t, uploadDir)
	file := models.File{
		Hash:        "private-emoji-asset",
		Path:        "/uploads/emoji/asset.png",
		Size:        5,
		MimeType:    "image/png",
		UploaderID:  7,
		Status:      "active",
		AccessScope: models.FileAccessPrivate,
		RefCount:    1,
	}
	require.NoError(t, db.Create(&file).Error)
	asset := models.UserEmojiAsset{
		UserID:        7,
		FileID:        file.ID,
		ThumbnailPath: "/uploads/emoji-thumbnails/asset.png",
		MimeType:      "image/png",
		Width:         8,
		Height:        8,
	}
	require.NoError(t, db.Create(&asset).Error)
	favorite := models.UserEmojiFavorite{
		UserID: 7,
		Kind:   models.EmojiFavoriteKindCustom,
		AssetID: func() *uint {
			id := asset.ID
			return &id
		}(),
	}
	require.NoError(t, db.Create(&favorite).Error)

	currentUserID := uint(7)
	r.Use(func(c *gin.Context) {
		c.Set("user_id", currentUserID)
		c.Next()
	})
	service := services.NewEmojiFavoriteService(db, uploadDir)
	handler := NewEmojiFavoriteHandler(service)
	r.GET("/api/emoji/favorites/:id/file", handler.ServeFile)
	r.GET("/api/emoji/favorites/:id/thumbnail", handler.ServeThumbnail)
	fileURL := fmt.Sprintf("/api/emoji/favorites/%d/file", favorite.ID)
	thumbnailURL := fmt.Sprintf("/api/emoji/favorites/%d/thumbnail", favorite.ID)

	ownerFile := httptest.NewRecorder()
	r.ServeHTTP(ownerFile, httptest.NewRequest(http.MethodGet, fileURL, nil))
	require.Equal(t, http.StatusOK, ownerFile.Code)
	require.Equal(t, "asset", ownerFile.Body.String())

	ownerThumbnail := httptest.NewRecorder()
	r.ServeHTTP(ownerThumbnail, httptest.NewRequest(http.MethodGet, thumbnailURL, nil))
	require.Equal(t, http.StatusOK, ownerThumbnail.Code)
	require.Equal(t, "thumb", ownerThumbnail.Body.String())

	currentUserID = 8
	foreign := httptest.NewRecorder()
	r.ServeHTTP(foreign, httptest.NewRequest(http.MethodGet, fileURL, nil))
	require.Equal(t, http.StatusNotFound, foreign.Code)
}
