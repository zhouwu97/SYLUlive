package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestEmojiPackCatalogManifestAndRange(t *testing.T) {
	gin.SetMode(gin.TestMode)
	router := gin.New()
	router.GET("/packs", ListEmojiPacks)
	router.GET("/packs/:id/manifest", GetEmojiPackManifest)
	router.GET("/packs/:id/assets/:assetId", GetEmojiPackAsset)
	if len(officialEmojiPacks) == 0 {
		t.Fatal("官方目录为空")
	}
	pack := officialEmojiPacks[0]
	recorder := httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest("GET", "/packs", nil))
	if recorder.Code != 200 {
		t.Fatal(recorder.Code)
	}
	recorder = httptest.NewRecorder()
	router.ServeHTTP(recorder, httptest.NewRequest("GET", "/packs/"+pack.ID+"/manifest", nil))
	hash := sha256.Sum256(recorder.Body.Bytes())
	if hex.EncodeToString(hash[:]) != pack.ManifestSHA256 {
		t.Fatal("Manifest Hash 不一致")
	}
	var manifest struct {
		Assets []struct {
			ID     string `json:"id"`
			SHA256 string `json:"sha256"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	asset := manifest.Assets[0]
	path := "/packs/" + pack.ID + "/assets/" + asset.ID
	recorder = httptest.NewRecorder()
	request := httptest.NewRequest("GET", path, nil)
	request.Header.Set("Range", "bytes=0-9")
	router.ServeHTTP(recorder, request)
	if recorder.Code != 206 || recorder.Body.Len() != 10 {
		t.Fatalf("Range 失败: %d %d", recorder.Code, recorder.Body.Len())
	}
	for _, path := range []string{path + "?version=1", "/packs/unknown/manifest", "/packs/" + pack.ID + "/assets/private-file"} {
		recorder = httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest("GET", path, nil))
		if recorder.Code != 404 {
			t.Fatalf("未阻断未知资源: %s", path)
		}
	}
}
