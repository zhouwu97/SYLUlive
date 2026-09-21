package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strconv"
	"strings"
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
		Version int `json:"version"`
		Assets  []struct {
			ID     string `json:"id"`
			SHA256 string `json:"sha256"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.Version != pack.Version {
		t.Fatalf("Manifest 版本与目录不一致: %d != %d", manifest.Version, pack.Version)
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
	for _, path := range []string{
		path + "?version=" + strconv.Itoa(pack.Version+1),
		"/packs/unknown/manifest",
		"/packs/" + pack.ID + "/assets/private-file",
	} {
		recorder = httptest.NewRecorder()
		router.ServeHTTP(recorder, httptest.NewRequest("GET", path, nil))
		if recorder.Code != 404 {
			t.Fatalf("未阻断未知资源: %s", path)
		}
	}
	recorder = httptest.NewRecorder()
	router.ServeHTTP(recorder,
		httptest.NewRequest("GET", "/packs/"+pack.ID+"/manifest?version="+strconv.Itoa(pack.Version), nil))
	if recorder.Code != 200 {
		t.Fatalf("按当前版本取 Manifest 失败: %d", recorder.Code)
	}
}

func TestOfficialEmojiPackVersionFollowsPublishedContent(t *testing.T) {
	assets := func(hash string) []map[string]any {
		return []map[string]any{
			{"id": "a", "path": "assets/a.png", "sha256": hash, "file_size": 12},
			{"id": "b", "path": "assets/b.png", "sha256": strings.Repeat("0", 64), "file_size": 30},
		}
	}
	first := officialEmojiPackVersion("official-pack", assets(strings.Repeat("1", 64)))
	stable := officialEmojiPackVersion("official-pack", assets(strings.Repeat("1", 64)))
	changed := officialEmojiPackVersion("official-pack", assets(strings.Repeat("2", 64)))
	if first != stable {
		t.Fatalf("相同资源的版本号不稳定: %d != %d", first, stable)
	}
	if first == changed {
		t.Fatal("资源内容变化后版本号未变化")
	}
	// 客户端把版本当整数比较并展示，必须留在 JSON 安全整数内且为正数。
	for _, version := range []int{first, changed} {
		if version < 1 || version > 1<<53 {
			t.Fatalf("版本号越界: %d", version)
		}
	}
	for _, pack := range officialEmojiPacks {
		if pack.Version < 1 {
			t.Fatalf("官方包 %s 版本无效: %d", pack.ID, pack.Version)
		}
	}
}
