package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
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
	h := NewAppUpdateHandler(svc)
	r := gin.New()
	r.GET("/api/app/update", h.CheckUpdate)
	return r
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
		"X-App-Platform":      "android",
		"X-App-Channel":        "stable",
		"X-App-Version-Name":   "1.6.1",
		"X-App-Version-Code":   "1601",
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
// 形如 "1.6.x"，SHA256 为 64 位 0 占位串。
func buildReleasePtrForUpdate(versionCode int64, status string, minimum int64) *models.AppRelease {
	r := models.AppRelease{
		Platform:                     models.AppReleasePlatformAndroid,
		Channel:                      models.AppReleaseChannelStable,
		VersionName:                  "1.6.x",
		VersionCode:                  versionCode,
		Title:                        "test",
		Changelog:                    "changelog",
		MinimumSupportedVersionCode:  minimum,
		FileName:                     "shenliyuan.apk",
		StorageKey:                   "android/stable/" + strconv.FormatInt(versionCode, 10) + "/shenliyuan.apk",
		FileSize:                     68,
		SHA256:                       "0000000000000000000000000000000000000000000000000000000000000000",
		Status:                       status,
	}
	return &r
}