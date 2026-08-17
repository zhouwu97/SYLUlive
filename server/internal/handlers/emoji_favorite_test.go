package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func newEmojiFavoriteHandlerTest(t *testing.T) (*gin.Engine, *gorm.DB) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:emoji_handler_test?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.File{}, &models.FileUploadGrant{}, &models.UserEmojiAsset{}, &models.UserEmojiFavorite{}))
	service := services.NewEmojiFavoriteService(db)
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
