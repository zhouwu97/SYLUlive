package handlers

import (
	"github.com/stretchr/testify/require"
	"net/http"
	"shenliyuan/internal/models"
	"testing"
)

func TestEmojiPackPrivacyExportAndAccountCancellation(t *testing.T) {
	h, db, user := newPrivacyTestHandler(t)
	require.NoError(t, db.AutoMigrate(&models.CommunityEmojiPack{}, &models.CommunityEmojiPackAsset{}))
	pack := models.CommunityEmojiPack{ID: "community-00000000-0000-0000-0000-000000000001", UserID: user.ID,
		RequestKey: "private-request-key", ContentHash: "internal-hash", Name: "我的投稿", Status: models.EmojiPackPublished,
		Manifest: []byte("private-manifest"), Assets: []models.CommunityEmojiPackAsset{{AssetID: "image-1", Name: "test", MimeType: "image/png"}}}
	require.NoError(t, db.Create(&pack).Error)
	c, response := privacyContext(http.MethodGet, "/api/privacy/my-data/export", "", user.ID)
	h.ExportMyData(c)
	require.Equal(t, 200, response.Code)
	require.Contains(t, response.Body.String(), "我的投稿")
	for _, hidden := range []string{"private-request-key", "internal-hash", "private-manifest"} {
		require.NotContains(t, response.Body.String(), hidden)
	}
	c, response = privacyContext(http.MethodPost, "/api/privacy/cancel-account", `{"password":"password123","confirmed":true}`, user.ID)
	h.CancelAccount(c)
	require.Equal(t, 200, response.Code, response.Body.String())
	require.NoError(t, db.First(&pack, "id = ?", pack.ID).Error)
	require.Equal(t, models.EmojiPackWithdrawn, pack.Status)
	var assets int64
	require.NoError(t, db.Model(&models.CommunityEmojiPackAsset{}).Count(&assets).Error)
	require.Zero(t, assets)
}
