package handlers

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func newAppUpdateTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AppRelease{}))
	return db
}

func newAppUpdateRouter(t *testing.T, db *gorm.DB) *gin.Engine {
	t.Helper()
	gin.SetMode(gin.TestMode)
	svc := services.NewAppReleaseService(db, t.TempDir())
	h := NewAppUpdateHandler(svc, false, "/_internal/app-releases/")
	r := gin.New()
	r.GET("/api/app/update", h.CheckUpdate)
	return r
}

// newAppUpdateDownloadRouter 构造带下载路由的路由。accelEnabled 控制是否走
// X-Accel-Redirect 分支；为了覆盖两种实现，测试需要分别构造。
func newAppUpdateDownloadRouter(t *testing.T, db *gorm.DB, releaseDir string, accelEnabled bool) (*gin.Engine, *AppUpdateHandler) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	svc := services.NewAppReleaseService(db, releaseDir)
	h := NewAppUpdateHandler(svc, accelEnabled, "/_internal/app-releases/")
	r := gin.New()
	r.GET("/api/app/update", h.CheckUpdate)
	r.GET("/api/app/releases/:id/download", h.Download)
	r.HEAD("/api/app/releases/:id/download", h.Download)
	return r, h
}

func mustDoUpdateRequest(t *testing.T, r *gin.Engine, target string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, target, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func decodeUpdateResponse(t *testing.T, w *httptest.ResponseRecorder) updateCheckResponse {
	t.Helper()
	require.Equalf(t, http.StatusOK, w.Code, "unexpected status, body=%s", w.Body.String())
	var resp updateCheckResponse
	require.NoErrorf(t, json.Unmarshal(w.Body.Bytes(), &resp), "decode body=%s", w.Body.String())
	return resp
}

func TestCheckUpdate_RejectsMissingVersionCode(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.1", nil)
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestCheckUpdate_RejectsInvalidVersionCode(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.1&version_code=abc", nil)
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestCheckUpdate_RejectsUnsupportedPlatform(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=ios&channel=stable&version_name=1.6.1&version_code=1601", nil)
	require.Equal(t, http.StatusBadRequest, w.Code)
	require.Contains(t, w.Body.String(), "unsupported_platform")
}

func TestCheckUpdate_OhosWithoutPublishedReleaseReturnsNoUpdate(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=ohos&channel=stable&version_name=1.6.2&version_code=1602", nil)
	require.Equal(t, http.StatusOK, w.Code)

	resp := decodeUpdateResponse(t, w)
	require.False(t, resp.UpdateAvailable)
	require.Equal(t, "none", resp.UpdateType)
	require.Equal(t, int64(1602), resp.LatestVersionCode)
}

func TestCheckUpdate_RejectsUnsupportedChannel(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=beta&version_name=1.6.1&version_code=1601", nil)
	require.Equal(t, http.StatusBadRequest, w.Code)
	require.Contains(t, w.Body.String(), "unsupported_channel")
}

func TestCheckUpdate_NoPublishedReleaseReturnsNoUpdate(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.1&version_code=1601", nil)
	resp := decodeUpdateResponse(t, w)
	require.False(t, resp.UpdateAvailable)
	require.Equal(t, "none", resp.UpdateType)
	require.Equal(t, int64(1601), resp.LatestVersionCode)
	require.Empty(t, resp.DownloadURL)
}

func TestCheckUpdate_HeadersFallback(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update", map[string]string{
		"X-App-Platform":     "android",
		"X-App-Channel":      "stable",
		"X-App-Version-Name": "1.6.1",
		"X-App-Version-Code": "1601",
	})
	resp := decodeUpdateResponse(t, w)
	require.False(t, resp.UpdateAvailable)
	require.Equal(t, int64(1601), resp.CurrentVersionCode)
}

func TestCheckUpdate_OptionalUpdate(t *testing.T) {
	db := newAppUpdateTestDB(t)
	require.NoError(t, db.Create(buildReleasePtrForUpdate(1602, models.AppReleaseStatusPublished, 1601)).Error)

	r := newAppUpdateRouter(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.1&version_code=1601", nil)
	resp := decodeUpdateResponse(t, w)
	require.True(t, resp.UpdateAvailable)
	require.Equal(t, "optional", resp.UpdateType)
	require.Equal(t, int64(1602), resp.LatestVersionCode)
	require.Equal(t, int64(1601), resp.MinimumSupportedVersionCode)
	require.NotEmpty(t, resp.DownloadURL)
	require.Contains(t, resp.DownloadURL, "/api/app/releases/")
	require.Equal(t, int64(68), resp.FileSize)
	require.Len(t, resp.SHA256, 64)
}

func TestCheckUpdate_ExternalMarket(t *testing.T) {
	db := newAppUpdateTestDB(t)
	rel := buildReleasePtrForUpdate(1602, models.AppReleaseStatusPublished, 1601)
	rel.Platform = models.AppReleasePlatformOhos
	rel.DeliveryMode = models.AppReleaseDeliveryModeExternalMarket
	rel.ActionURL = "appgallery://..."
	require.NoError(t, db.Create(rel).Error)

	r := newAppUpdateRouter(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=ohos&channel=stable&version_name=1.6.1&version_code=1601", nil)
	resp := decodeUpdateResponse(t, w)
	
	require.True(t, resp.UpdateAvailable)
	require.Equal(t, "optional", resp.UpdateType)
	require.Equal(t, "external_market", resp.DeliveryMode)
	require.Equal(t, "appgallery://...", resp.ActionURL)
	require.Empty(t, resp.DownloadURL)
	require.Empty(t, resp.FileSize)
	require.Empty(t, resp.SHA256)
}

func TestCheckUpdate_RequiredUpdate(t *testing.T) {
	db := newAppUpdateTestDB(t)
	require.NoError(t, db.Create(buildReleasePtrForUpdate(1603, models.AppReleaseStatusPublished, 1602)).Error)

	r := newAppUpdateRouter(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.1&version_code=1601", nil)
	resp := decodeUpdateResponse(t, w)
	require.True(t, resp.UpdateAvailable)
	require.Equal(t, "required", resp.UpdateType)
	require.Equal(t, int64(1603), resp.LatestVersionCode)
	require.Equal(t, int64(1602), resp.MinimumSupportedVersionCode)
}

func TestCheckUpdate_UpToDateVersionReturnsNone(t *testing.T) {
	db := newAppUpdateTestDB(t)
	require.NoError(t, db.Create(buildReleasePtrForUpdate(1603, models.AppReleaseStatusPublished, 1601)).Error)

	r := newAppUpdateRouter(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.3&version_code=1603", nil)
	resp := decodeUpdateResponse(t, w)
	require.False(t, resp.UpdateAvailable)
	require.Equal(t, "none", resp.UpdateType)
	require.Empty(t, resp.DownloadURL)
	require.Equal(t, int64(1603), resp.LatestVersionCode)
}

func TestCheckUpdate_IgnoresDraftAndWithdrawn(t *testing.T) {
	db := newAppUpdateTestDB(t)
	require.NoError(t, db.Create(buildReleasePtrForUpdate(1601, models.AppReleaseStatusDraft, 1601)).Error)
	require.NoError(t, db.Create(buildReleasePtrForUpdate(1602, models.AppReleaseStatusWithdrawn, 1602)).Error)

	r := newAppUpdateRouter(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_name=1.6.1&version_code=1601", nil)
	resp := decodeUpdateResponse(t, w)
	require.False(t, resp.UpdateAvailable)
	require.Empty(t, resp.DownloadURL)
}

func TestCheckUpdate_RequiresVersionName(t *testing.T) {
	r := newAppUpdateRouter(t, newAppUpdateTestDB(t))
	w := mustDoUpdateRequest(t, r, "/api/app/update?platform=android&channel=stable&version_code=1601", nil)
	require.Equal(t, http.StatusBadRequest, w.Code)
	require.Contains(t, w.Body.String(), "missing_version_name")
}

// buildReleasePtrForUpdate 创建一个最小可写入数据库的 AppRelease。versionCode
// buildReleasePtrForUpdate 创建一个最小可写入数据库的 AppRelease。versionCode
// 形如 "1.6.x"，SHA256 为 64 位 0 占位串。
func buildReleasePtrForUpdate(versionCode int64, status string, minimum int64) *models.AppRelease {
	r := models.AppRelease{
		Platform:                    models.AppReleasePlatformAndroid,
		Channel:                     models.AppReleaseChannelStable,
		VersionName:                 "1.6.x",
		VersionCode:                 versionCode,
		Title:                       "test",
		Changelog:                   "changelog",
		MinimumSupportedVersionCode: minimum,
		FileName:                    "shenliyuan.apk",
		StorageKey:                  "android/stable/" + strconv.FormatInt(versionCode, 10) + "/shenliyuan.apk",
		FileSize:                    68,
		SHA256:                      "0000000000000000000000000000000000000000000000000000000000000000",
		Status:                      status,
	}
	return &r
}

// seedRealAPK 在 releaseDir 下按 storageKey 写一个真实磁盘 APK，body 全是
// deterministic 字节，便于测试 Range 与 SHA-256 校验。返回 sha256 hex。
// 用 latestReleaseID(t, db) 取创建后的主键 ID。
func seedRealAPK(t *testing.T, db *gorm.DB, releaseDir string, versionCode int64, status string, content []byte) string {
	t.Helper()
	storageKey := "android/stable/" + strconv.FormatInt(versionCode, 10) + "/shenliyuan-" + strconv.FormatInt(versionCode, 10) + ".apk"
	fullPath := filepath.Join(releaseDir, filepath.FromSlash(storageKey))
	require.NoError(t, os.MkdirAll(filepath.Dir(fullPath), 0o755))
	require.NoError(t, os.WriteFile(fullPath, content, 0o644))

	sum := sha256.Sum256(content)
	sumHex := hex.EncodeToString(sum[:])
	r := &models.AppRelease{
		Platform:                    models.AppReleasePlatformAndroid,
		Channel:                     models.AppReleaseChannelStable,
		VersionName:                 "1.6.x",
		VersionCode:                 versionCode,
		Title:                       "test",
		Changelog:                   "changelog",
		MinimumSupportedVersionCode: 1601,
		FileName:                    "shenliyuan-" + strconv.FormatInt(versionCode, 10) + ".apk",
		StorageKey:                  storageKey,
		FileSize:                    int64(len(content)),
		SHA256:                      sumHex,
		Status:                      status,
	}
	require.NoError(t, db.Create(r).Error)
	require.NotZero(t, r.ID)
	return sumHex
}

func TestDownload_ServeContent_FullFile(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	content := bytes.Repeat([]byte("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4) // 104 bytes
	sumHex := seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusPublished, content)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	url := "/api/app/releases/" + formatID(latestReleaseID(t, db)) + "/download"
	w := mustDoUpdateRequest(t, r, url, nil)
	require.Equal(t, http.StatusOK, w.Code)
	require.Equal(t, "application/vnd.android.package-archive", w.Header().Get("Content-Type"))
	require.Equal(t, "bytes", w.Header().Get("Accept-Ranges"))
	require.Equal(t, strconv.Itoa(len(content)), w.Header().Get("Content-Length"))
	require.Equal(t, `"`+sumHex+`"`, w.Header().Get("ETag"))
	require.Contains(t, w.Header().Get("Content-Disposition"), "shenliyuan-1602.apk")
	require.Equal(t, "nosniff", w.Header().Get("X-Content-Type-Options"))
	require.Equal(t, content, w.Body.Bytes())
}

func TestDownload_ServeContent_RangeReturns206(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	content := bytes.Repeat([]byte("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4)
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusPublished, content)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	id := latestReleaseID(t, db)
	req := httptest.NewRequest(http.MethodGet, "/api/app/releases/"+formatID(id)+"/download", nil)
	req.Header.Set("Range", "bytes=0-15")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	require.Equal(t, http.StatusPartialContent, w.Code)
	require.Equal(t, "bytes 0-15/"+strconv.Itoa(len(content)), w.Header().Get("Content-Range"))
	require.Equal(t, "16", w.Header().Get("Content-Length"))
	require.Equal(t, content[:16], w.Body.Bytes())
}

func TestDownload_ServeContent_HEADReturnsNoBody(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	content := bytes.Repeat([]byte("AB"), 80)
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusPublished, content)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	id := latestReleaseID(t, db)
	req := httptest.NewRequest(http.MethodHead, "/api/app/releases/"+formatID(id)+"/download", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	require.Equal(t, http.StatusOK, w.Code)
	require.Equal(t, "application/vnd.android.package-archive", w.Header().Get("Content-Type"))
	require.Equal(t, strconv.Itoa(len(content)), w.Header().Get("Content-Length"))
	require.Empty(t, w.Body.Bytes())
}

func TestDownload_InvalidIDRejected(t *testing.T) {
	db := newAppUpdateTestDB(t)
	r, _ := newAppUpdateDownloadRouter(t, db, t.TempDir(), false)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/abc/download", nil)
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestDownload_UnknownIDReturns404(t *testing.T) {
	db := newAppUpdateTestDB(t)
	r, _ := newAppUpdateDownloadRouter(t, db, t.TempDir(), false)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/9999/download", nil)
	require.Equal(t, http.StatusNotFound, w.Code)
	require.Contains(t, w.Body.String(), "release_not_found")
}

func TestDownload_RejectsWithdrawnRelease(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	content := bytes.Repeat([]byte("AB"), 80)
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusWithdrawn, content)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	id := latestReleaseID(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/"+formatID(id)+"/download", nil)
	require.Equal(t, http.StatusNotFound, w.Code)
	require.Contains(t, w.Body.String(), "release_not_downloadable")
}

func TestDownload_RejectsDraftRelease(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	content := bytes.Repeat([]byte("AB"), 80)
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusDraft, content)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	id := latestReleaseID(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/"+formatID(id)+"/download", nil)
	require.Equal(t, http.StatusNotFound, w.Code)
}

func TestDownload_FileMissingOnDiskReturns404(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	// 写文件然后立即删除，模拟线上文件丢失但 DB 状态仍为 published。
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusPublished, bytes.Repeat([]byte("A"), 10))
	id := latestReleaseID(t, db)
	// 查出 storageKey 并删除磁盘文件。
	var rel models.AppRelease
	require.NoError(t, db.First(&rel, id).Error)
	require.NoError(t, os.Remove(filepath.Join(releaseDir, filepath.FromSlash(rel.StorageKey))))

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/"+formatID(id)+"/download", nil)
	require.Equal(t, http.StatusNotFound, w.Code)
	require.Contains(t, w.Body.String(), "release_file_missing")
}

func TestDownload_SizeMismatchReturns503(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusPublished, bytes.Repeat([]byte("A"), 10))
	id := latestReleaseID(t, db)
	// 篡改 FileSize，使 DB 与磁盘真实大小不一致。
	require.NoError(t, db.Model(&models.AppRelease{}).Where("id = ?", id).Update("file_size", 9999).Error)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/"+formatID(id)+"/download", nil)
	require.Equal(t, http.StatusServiceUnavailable, w.Code)
	require.Contains(t, w.Body.String(), "release_size_mismatch")
}

func TestDownload_RejectsTraversalStorageKey(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	// 手动插入一条 status=published 但 storage_key 是穿越攻击中常见的形状。
	rel := &models.AppRelease{
		Platform:                    models.AppReleasePlatformAndroid,
		Channel:                     models.AppReleaseChannelStable,
		VersionName:                 "1.6.x",
		VersionCode:                 1602,
		Title:                       "test",
		Changelog:                   "changelog",
		MinimumSupportedVersionCode: 1601,
		FileName:                    "evil.apk",
		StorageKey:                  "android/stable/../../../../etc/passwd",
		FileSize:                    10,
		SHA256:                      strings.Repeat("0", 64),
		Status:                      models.AppReleaseStatusPublished,
	}
	require.NoError(t, db.Create(rel).Error)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, false)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/"+formatID(rel.ID)+"/download", nil)
	// LocateAPK 拒绝穿越 → 500 storage_misconfigured。
	require.Equal(t, http.StatusInternalServerError, w.Code)
	require.Contains(t, w.Body.String(), "storage_misconfigured")
}

func TestDownload_AccelModeSetsHeaderNoBody(t *testing.T) {
	db := newAppUpdateTestDB(t)
	releaseDir := t.TempDir()
	content := bytes.Repeat([]byte("AB"), 80)
	seedRealAPK(t, db, releaseDir, 1602, models.AppReleaseStatusPublished, content)

	r, _ := newAppUpdateDownloadRouter(t, db, releaseDir, true)
	id := latestReleaseID(t, db)
	w := mustDoUpdateRequest(t, r, "/api/app/releases/"+formatID(id)+"/download", nil)
	require.Equal(t, http.StatusOK, w.Code)
	// X-Accel-Redirect 应指向 /_internal/app-releases/<relative> 形式。
	accel := w.Header().Get("X-Accel-Redirect")
	require.NotEmpty(t, accel)
	require.True(t, strings.HasPrefix(accel, "/_internal/app-releases/"))
	require.True(t, strings.HasSuffix(accel, "/android/stable/1602/shenliyuan-1602.apk"))
	// Nginx 负责投递文件，不应通过 Go 写出正文。
	require.Empty(t, w.Body.Bytes())
	// Cache-Control / Content-Type 仍应下发，便于客户端缓存协商。
	require.Equal(t, "application/vnd.android.package-archive", w.Header().Get("Content-Type"))
}

// latestReleaseID 返回 DB 中最新一条 AppRelease 的 ID，便于测试拼接 URL。
func latestReleaseID(t *testing.T, db *gorm.DB) uint {
	t.Helper()
	var rel models.AppRelease
	require.NoError(t, db.Order("id DESC").First(&rel).Error)
	return rel.ID
}

func formatID(id uint) string { return strconv.FormatUint(uint64(id), 10) }
