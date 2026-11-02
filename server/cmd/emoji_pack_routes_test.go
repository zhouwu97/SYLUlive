package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"io"
	"mime/multipart"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"shenliyuan/internal/middleware"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

type emojiPackRouteFixture struct {
	db     *gorm.DB
	router *gin.Engine
	dir    string
	tokens map[uint]string
	png    []byte
	names  string
}

func newEmojiPackRoutesFixture(t *testing.T) *emojiPackRouteFixture {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	sqlDB, err := db.DB()
	require.NoError(t, err)
	sqlDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = sqlDB.Close() })
	for i := 0; i < 2; i++ {
		require.NoError(t, db.AutoMigrate(&models.User{}, &models.UserLegalConsent{}, &models.AdminLog{}, &models.CommunityEmojiPack{}, &models.CommunityEmojiPackAsset{}))
	}
	middleware.InvalidateTokenVersionCache(0)
	middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementOff)
	t.Cleanup(func() {
		middleware.InvalidateTokenVersionCache(0)
		middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementSoft)
	})
	f := &emojiPackRouteFixture{db: db, router: gin.New(), dir: t.TempDir(), tokens: map[uint]string{}}
	f.router.Use(middleware.RequestBodyLimitMiddleware(1<<20,
		middleware.BodyLimitRule{Prefix: "/api/emoji/submissions", Limit: services.EmojiPackMaxUploadBytes}))
	f.router.Use(middleware.IdempotencyMiddlewareWithJWT(db, "emoji-test-secret"))
	for id, role := range map[uint]models.Role{1: models.RoleUser, 2: models.RoleUser, 3: models.RoleAdmin} {
		require.NoError(t, db.Create(&models.User{ID: id, PasswordHash: "fixture", Role: role, Nickname: fmt.Sprintf("user-%d", id)}).Error)
		f.tokens[id], err = middleware.GenerateToken(id, string(role), 0, "emoji-test-secret")
		require.NoError(t, err)
	}
	var output bytes.Buffer
	require.NoError(t, png.Encode(&output, image.NewRGBA(image.Rect(0, 0, 3, 3))))
	f.png = output.Bytes()
	registerEmojiPackRoutes(f.router, db, f.dir, "emoji-test-secret")
	return f
}

func (f *emojiPackRouteFixture) request(method, path string, user uint, body io.Reader, headers map[string]string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, body)
	if user != 0 {
		request.Header.Set("Authorization", "Bearer "+f.tokens[user])
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response := httptest.NewRecorder()
	f.router.ServeHTTP(response, request)
	return response
}

func (f *emojiPackRouteFixture) upload(t *testing.T, user uint, key, name, rights string, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	for key, value := range map[string]string{"name": name, "description": "校园测试包", "names": `["第一张"]`, "rights_confirmed": rights} {
		if key == "names" && f.names != "" {
			value = f.names
		}
		require.NoError(t, writer.WriteField(key, value))
	}
	file, err := writer.CreateFormFile("images", "untrusted-name.png")
	require.NoError(t, err)
	_, err = file.Write(data)
	require.NoError(t, err)
	require.NoError(t, writer.Close())
	return f.request("POST", "/api/emoji/submissions", user, &body, map[string]string{"Content-Type": writer.FormDataContentType(), "Idempotency-Key": key})
}

func (f *emojiPackRouteFixture) review(id, action, reason string, user uint) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"action": action, "reason": reason})
	return f.request("POST", "/api/admin/emoji-packs/"+id+"/review", user, bytes.NewReader(body), map[string]string{"Content-Type": "application/json"})
}

func emojiPackResponse(t *testing.T, response *httptest.ResponseRecorder) models.CommunityEmojiPack {
	t.Helper()
	require.Equal(t, 200, response.Code, response.Body.String())
	var pack models.CommunityEmojiPack
	require.NoError(t, json.Unmarshal(response.Body.Bytes(), &pack))
	return pack
}

func TestEmojiPackRoutesSubmissionReviewDownloadAndWithdrawal(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	require.Equal(t, 401, f.upload(t, 0, strings.Repeat("a", 16), "测试包", "true", f.png).Code)
	require.Equal(t, 400, f.upload(t, 1, strings.Repeat("a", 16), "测试包", "false", f.png).Code)
	require.Equal(t, 400, f.upload(t, 1, strings.Repeat("a", 16), "测试包", "true", []byte("not an image")).Code)
	pack := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("a", 16), "测试包", "true", f.png))
	require.Equal(t, models.EmojiPackPending, pack.Status)
	again := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("a", 16), "测试包", "true", f.png))
	require.Equal(t, pack.ID, again.ID)
	require.Equal(t, 409, f.upload(t, 1, strings.Repeat("a", 16), "不同内容", "true", f.png).Code)
	for _, path := range []string{"/api/emoji/packs/" + pack.ID, "/api/emoji/packs/" + pack.ID + "/manifest", "/api/emoji/packs/" + pack.ID + "/assets/image-1"} {
		require.Equal(t, 404, f.request("GET", path, 0, nil, nil).Code)
	}
	for _, path := range []string{"/api/emoji/submissions/" + pack.ID, "/api/emoji/submissions/" + pack.ID + "/assets/image-1"} {
		require.Equal(t, 404, f.request("GET", path, 2, nil, nil).Code)
	}
	require.Equal(t, 404, f.request("DELETE", "/api/emoji/submissions/"+pack.ID, 2, nil, nil).Code)
	require.NotContains(t, f.request("GET", "/api/emoji/submissions", 2, nil, nil).Body.String(), pack.ID)
	require.Equal(t, 403, f.request("GET", "/api/admin/emoji-packs", 1, nil, nil).Code)
	ownerAsset := f.request("GET", "/api/emoji/submissions/"+pack.ID+"/assets/image-1", 1, nil, map[string]string{"Range": "bytes=0-9"})
	require.Equal(t, 206, ownerAsset.Code)
	require.Equal(t, "private, no-store", ownerAsset.Header().Get("Cache-Control"))
	require.Equal(t, 200, f.request("GET", "/api/admin/emoji-packs/"+pack.ID, 3, nil, nil).Code)
	require.Equal(t, 400, f.review(pack.ID, "reject", "", 3).Code)
	require.Equal(t, 200, f.review(pack.ID, "approve", "", 3).Code)
	require.Equal(t, 409, f.review(pack.ID, "reject", "过期审核", 3).Code)
	require.NotContains(t, f.request("GET", "/api/emoji/packs", 0, nil, nil).Body.String(), pack.ID)
	catalog := f.request("GET", "/api/emoji/packs?include_community=true", 0, nil, nil)
	require.Contains(t, catalog.Body.String(), pack.ID)
	publicDetail := f.request("GET", "/api/emoji/packs/"+pack.ID, 0, nil, nil)
	require.NotContains(t, publicDetail.Body.String(), "user_id")
	manifest := f.request("GET", "/api/emoji/packs/"+pack.ID+"/manifest?version=1", 0, nil, nil)
	require.Equal(t, 200, manifest.Code)
	sum := sha256.Sum256(manifest.Body.Bytes())
	require.Equal(t, pack.ManifestSHA256, hex.EncodeToString(sum[:]))
	var parsed struct {
		Assets []struct {
			SHA256 string `json:"sha256"`
		} `json:"assets"`
	}
	require.NoError(t, json.Unmarshal(manifest.Body.Bytes(), &parsed))
	asset := f.request("GET", "/api/emoji/packs/"+pack.ID+"/assets/image-1?version=1", 0, nil, nil)
	require.Equal(t, 200, asset.Code)
	sum = sha256.Sum256(asset.Body.Bytes())
	require.Equal(t, parsed.Assets[0].SHA256, hex.EncodeToString(sum[:]))
	require.Equal(t, "no-store", asset.Header().Get("Cache-Control"))
	require.Equal(t, 206, f.request("GET", "/api/emoji/packs/"+pack.ID+"/assets/image-1", 0, nil, map[string]string{"Range": "bytes=0-9"}).Code)
	require.Equal(t, 404, f.request("GET", "/api/emoji/packs/"+pack.ID+"/manifest?version=2", 0, nil, nil).Code)
	require.Equal(t, 200, f.review(pack.ID, "unpublish", "授权需要补充", 3).Code)
	require.NotContains(t, f.request("GET", "/api/emoji/packs?include_community=true", 0, nil, nil).Body.String(), pack.ID)
	require.Equal(t, 404, f.request("GET", "/api/emoji/packs/"+pack.ID+"/assets/image-1", 0, nil, nil).Code)
	require.Contains(t, f.request("GET", "/api/emoji/submissions/"+pack.ID, 1, nil, nil).Body.String(), "授权需要补充")
	for i := 0; i < 2; i++ {
		require.Equal(t, 200, f.request("DELETE", "/api/emoji/submissions/"+pack.ID, 1, nil, nil).Code)
	}
	require.Equal(t, 404, f.request("GET", "/api/emoji/submissions/"+pack.ID+"/assets/image-1", 1, nil, nil).Code)
	_, err := os.Stat(filepath.Join(f.dir, ".emoji-submissions", pack.ID))
	require.True(t, os.IsNotExist(err))
	var logs int64
	require.NoError(t, f.db.Model(&models.AdminLog{}).Count(&logs).Error)
	require.Equal(t, int64(2), logs)
}

func TestEmojiPackRoutesQuotaSelfReviewAndRevocation(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	self := emojiPackResponse(t, f.upload(t, 3, strings.Repeat("b", 16), "管理员投稿", "true", f.png))
	require.Equal(t, 403, f.review(self.ID, "approve", "", 3).Code)
	var pack models.CommunityEmojiPack
	for i := 0; i < 5; i++ {
		pack = emojiPackResponse(t, f.upload(t, 1, fmt.Sprintf("request-key-%05d", i), "配额测试", "true", f.png))
	}
	require.Equal(t, 429, f.upload(t, 1, "request-key-00005", "配额测试", "true", f.png).Code)
	require.Equal(t, 200, f.upload(t, 1, "request-key-00004", "配额测试", "true", f.png).Code)
	require.Equal(t, 400, f.request("GET", "/api/admin/emoji-packs?limit=999", 3, nil, nil).Code)
	// 保留旧 JWT 与认证缓存，handler 也必须阻断已降权管理员。
	require.Equal(t, 200, f.request("GET", "/api/admin/emoji-packs", 3, nil, nil).Code)
	require.NoError(t, f.db.Model(&models.User{}).Where("id = ?", 3).Update("role", models.RoleUser).Error)
	require.Equal(t, 403, f.request("GET", "/api/admin/emoji-packs", 3, nil, nil).Code)
	require.Equal(t, 403, f.review(pack.ID, "approve", "", 3).Code)
	require.Equal(t, 403, f.request("GET", "/api/admin/emoji-packs/"+pack.ID+"/assets/image-1", 3, nil, nil).Code)
}

func TestEmojiPackRoutesConcurrentReviewHasOneWinner(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	pack := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("c", 16), "并发测试", "true", f.png))
	var group sync.WaitGroup
	codes := make(chan int, 2)
	for _, action := range []string{"approve", "reject"} {
		group.Add(1)
		go func(action string) { defer group.Done(); codes <- f.review(pack.ID, action, "已检查", 3).Code }(action)
	}
	group.Wait()
	close(codes)
	observed := map[int]int{}
	for code := range codes {
		observed[code]++
	}
	require.Equal(t, map[int]int{200: 1, 409: 1}, observed)
}

func TestEmojiPackRoutesCanonicalNamesAndCommunityRules(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	f.names = `["喜欢<&😊"]`
	pack := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("d", 16), strings.Repeat("👨‍👩‍👧‍👦", 8), "true", f.png))
	require.Equal(t, 200, f.review(pack.ID, "approve", "", 3).Code)
	manifest := f.request("GET", "/api/emoji/packs/"+pack.ID+"/manifest", 0, nil, nil)
	require.Contains(t, manifest.Body.String(), "喜欢<&😊")
	require.NotContains(t, manifest.Body.String(), `\u003c`)
	for _, doc := range models.RequiredLegalDocuments(false) {
		require.NoError(t, f.db.Create(&models.UserLegalConsent{UserID: 1, Document: doc, Version: models.LegalDocumentVersion,
			Scene: "register", AcknowledgementType: "explicit_acceptance", AcceptedAt: time.Now()}).Error)
	}
	middleware.InvalidateTokenVersionCache(1)
	middleware.SetLegalConsentEnforcement(middleware.LegalConsentEnforcementHard)
	response := f.upload(t, 1, strings.Repeat("e", 16), "新投稿", "true", f.png)
	require.Equal(t, 403, response.Code)
	require.Contains(t, response.Body.String(), "community_rules_required")
	require.NoError(t, f.db.Create(&models.UserLegalConsent{UserID: 1, Document: models.LegalDocumentCommunityRules, Version: models.LegalDocumentVersion,
		Scene: "first_write", AcknowledgementType: "rules_acceptance", AcceptedAt: time.Now()}).Error)
	require.Equal(t, 200, f.upload(t, 1, strings.Repeat("e", 16), "新投稿", "true", f.png).Code)
}

func TestEmojiPackRoutesUseBusinessIdempotencyForLargeMultipart(t *testing.T) {
	f := newEmojiPackRoutesFixture(t)
	content := append(append([]byte{}, f.png...), make([]byte, (1<<20)+1)...)
	pack := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("f", 16), "超过 1 MiB 的合法图片", "true", content))
	again := emojiPackResponse(t, f.upload(t, 1, strings.Repeat("f", 16), "超过 1 MiB 的合法图片", "true", content))
	require.Equal(t, pack.ID, again.ID)
	f.router.POST("/api/unrelated-write", func(c *gin.Context) { c.Status(200) })
	response := f.request("POST", "/api/unrelated-write", 1, bytes.NewReader(content), map[string]string{"Idempotency-Key": strings.Repeat("a", 16)})
	require.Equal(t, 413, response.Code)
	require.Contains(t, response.Body.String(), "request_body_too_large")
}
