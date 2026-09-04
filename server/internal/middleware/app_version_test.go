package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newAppVersionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AppRelease{}))
	return db
}

func createPublishedRelease(t *testing.T, db *gorm.DB, versionCode, minimum int64) models.AppRelease {
	t.Helper()
	now := time.Now().UTC()
	release := models.AppRelease{
		Platform:                    models.AppReleasePlatformAndroid,
		Channel:                     models.AppReleaseChannelStable,
		VersionName:                 "1.6.3",
		VersionCode:                 versionCode,
		Title:                       "测试版本",
		Changelog:                   "测试更新说明",
		MinimumSupportedVersionCode: minimum,
		FileName:                    "test.apk",
		StorageKey:                  "android/stable/test.apk",
		FileSize:                    123,
		SHA256:                      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		Status:                      models.AppReleaseStatusPublished,
		PublishedAt:                 &now,
	}
	require.NoError(t, db.Create(&release).Error)
	return release
}

func newAppVersionRouter(db *gorm.DB, allowMissing bool) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(AppVersionMiddleware(db, true, allowMissing))
	r.GET("/api/business", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	r.GET("/api/app/update", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	r.POST("/api/login", func(c *gin.Context) { c.Status(http.StatusNoContent) })
	return r
}

func appVersionRequest(method, path, versionCode string) *http.Request {
	req := httptest.NewRequest(method, path, nil)
	if versionCode != "" {
		req.Header.Set(appVersionPlatformHeader, models.AppReleasePlatformAndroid)
		req.Header.Set(appVersionChannelHeader, models.AppReleaseChannelStable)
		req.Header.Set(appVersionNameHeader, "1.6.3")
		req.Header.Set(appVersionCodeHeader, versionCode)
	}
	return req
}

func TestAppVersionMiddlewareRejectsUnsupportedVersion(t *testing.T) {
	db := newAppVersionTestDB(t)
	createPublishedRelease(t, db, 1603, 1602)
	r := newAppVersionRouter(db, false)

	response := httptest.NewRecorder()
	r.ServeHTTP(response, appVersionRequest(http.MethodGet, "/api/business", "1601"))

	require.Equal(t, http.StatusUpgradeRequired, response.Code)
	require.JSONEq(t, `{
		"code":"APP_UPDATE_REQUIRED",
		"message":"当前版本已停止服务，请更新后继续使用",
		"update":{
			"update_type":"required",
			"latest_version_name":"1.6.3",
			"latest_version_code":1603,
			"minimum_supported_version_code":1602,
			"download_url":"/api/app/releases/1/download",
			"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			"file_size":123
		}
	}`, response.Body.String())
}

func TestAppVersionMiddlewareAllowsSupportedAndExemptRequests(t *testing.T) {
	db := newAppVersionTestDB(t)
	createPublishedRelease(t, db, 1603, 1602)
	r := newAppVersionRouter(db, false)

	for _, request := range []*http.Request{
		appVersionRequest(http.MethodGet, "/api/business", "1602"),
		appVersionRequest(http.MethodGet, "/api/app/update", ""),
		appVersionRequest(http.MethodPost, "/api/login", ""),
	} {
		response := httptest.NewRecorder()
		r.ServeHTTP(response, request)
		require.Equal(t, http.StatusNoContent, response.Code)
	}
}

func TestAppVersionMiddlewareHonorsMissingHeaderCompatibility(t *testing.T) {
	db := newAppVersionTestDB(t)
	createPublishedRelease(t, db, 1603, 1602)

	compatible := httptest.NewRecorder()
	newAppVersionRouter(db, true).ServeHTTP(compatible, appVersionRequest(http.MethodGet, "/api/business", ""))
	require.Equal(t, http.StatusNoContent, compatible.Code)

	enforced := httptest.NewRecorder()
	newAppVersionRouter(db, false).ServeHTTP(enforced, appVersionRequest(http.MethodGet, "/api/business", ""))
	require.Equal(t, http.StatusUpgradeRequired, enforced.Code)
}

func TestAppVersionMiddlewareAllowsRequestsBeforeAnyRelease(t *testing.T) {
	db := newAppVersionTestDB(t)
	r := newAppVersionRouter(db, false)

	response := httptest.NewRecorder()
	r.ServeHTTP(response, appVersionRequest(http.MethodGet, "/api/business", "1"))
	require.Equal(t, http.StatusNoContent, response.Code)
}
