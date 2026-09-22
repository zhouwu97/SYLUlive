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

func TestOfficialEmojiPackReleaseGuard(t *testing.T) {
	publishedAssets := func(hash string) []map[string]any {
		return []map[string]any{
			{"id": "a", "path": "assets/a.png", "sha256": hash, "file_size": 12},
			{"id": "b", "path": "assets/b.png", "sha256": strings.Repeat("0", 64), "file_size": 30},
		}
	}
	digestOf := func(hash string) string {
		sum := sha256.Sum256(officialEmojiPackContent("official-pack", publishedAssets(hash)))
		return hex.EncodeToString(sum[:])
	}
	// 发布序号缺失就没有可比较的身份，必须拒绝。
	if err := officialEmojiPackReleaseError("official-pack", 0, digestOf("1"), publishedAssets("1")); err == nil {
		t.Fatal("缺少发布版本号时未被拒绝")
	}
	// 资源变了却没登记新摘要：客户端认「同版本内容不可修改」，放出去会让用户永远拿不到新资源。
	if err := officialEmojiPackReleaseError("official-pack", 2, digestOf("1"), publishedAssets("2")); err == nil {
		t.Fatal("内容与登记摘要不一致时未被拒绝")
	}
	// version 刻意不进内容指纹：提升发布序号只登记新序号，不需要重算资源内容。
	if err := officialEmojiPackReleaseError("official-pack", 3, digestOf("1"), publishedAssets("1")); err != nil {
		t.Fatalf("发布校验误报: %v", err)
	}
}

// 首次发布官方包时使用的版本，此后只能前进；也是已安装客户端认知里的最低水位。
const firstPublishedOfficialEmojiPackVersion = 2026072901

func TestOfficialEmojiPacksDeclareReleaseIdentity(t *testing.T) {
	data, err := stickerAssetFS.ReadFile("sticker_assets/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	var groups []stickerCatalogGroup
	if err := json.Unmarshal(data, &groups); err != nil {
		t.Fatal(err)
	}
	if len(groups) != len(officialEmojiPacks) {
		t.Fatalf("catalog 分组数 %d 与官方包数 %d 不一致", len(groups), len(officialEmojiPacks))
	}
	// 资源内容与 content_sha256 的比对发生在包加载时（不一致直接 panic），
	// 这里只校验发布序号本身：必须是 JSON 安全整数、不回退、且登记了内容摘要。
	for _, group := range groups {
		if group.Version < firstPublishedOfficialEmojiPackVersion {
			t.Fatalf("官方包 %s 的发布序号回退到已发布版本之前: %d", group.ID, group.Version)
		}
		if group.Version > 1<<53 {
			t.Fatalf("官方包 %s 的发布序号超出 JSON 安全整数: %d", group.ID, group.Version)
		}
		digest, err := hex.DecodeString(group.ContentSHA256)
		if err != nil || len(digest) != 32 {
			t.Fatalf("官方包 %s 的 content_sha256 不是 64 位十六进制: %q", group.ID, group.ContentSHA256)
		}
	}
	for _, pack := range officialEmojiPacks {
		var manifest struct {
			Version int `json:"version"`
		}
		if err := json.Unmarshal(pack.manifest, &manifest); err != nil {
			t.Fatal(err)
		}
		if manifest.Version != pack.Version {
			t.Fatalf("官方包 %s 的 Manifest 版本与发布序号不一致: %d != %d", pack.ID, manifest.Version, pack.Version)
		}
	}
}
