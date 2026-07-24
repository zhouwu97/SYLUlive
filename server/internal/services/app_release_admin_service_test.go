package services

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strconv"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newAppReleaseAdminTestService(t *testing.T) (*AppReleaseService, *gorm.DB, models.User) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.AdminLog{}, &models.AppRelease{}))
	admin := models.User{
		StudentID:    "release-admin",
		PasswordHash: "test-password",
		Nickname:     "版本管理员",
		Role:         models.RoleSuperAdmin,
	}
	require.NoError(t, db.Create(&admin).Error)
	return NewAppReleaseService(db, t.TempDir(), 1024*1024), db, admin
}

func apkFixture(versionCode int64) []byte {
	// 发布服务目前只需要验证 APK/ZIP 本地文件头，完整签名校验交给 Android
	// 系统安装器与正式构建流程；这里用最小可识别 ZIP 头覆盖上传链路。
	return append([]byte("PK\x03\x04"), bytes.Repeat([]byte{byte(versionCode % 251)}, 32)...)
}

func createAppReleaseDraftForTest(
	t *testing.T,
	svc *AppReleaseService,
	admin models.User,
	versionCode, minimum int64,
) *models.AppRelease {
	t.Helper()
	release, err := svc.CreateDraft(
		context.Background(),
		AppReleaseDraftInput{
			Platform:                    models.AppReleasePlatformAndroid,
			Channel:                     models.AppReleaseChannelStable,
			VersionName:                 "1.6." + strconv.FormatInt(versionCode%10, 10),
			VersionCode:                 versionCode,
			Title:                       "测试更新",
			Changelog:                   "测试更新说明",
			MinimumSupportedVersionCode: minimum,
			CreatedBy:                   admin.ID,
			DeliveryMode:                models.AppReleaseDeliveryModeDirectPackage,
		},
		"shenliyuan.apk",
		bytes.NewReader(apkFixture(versionCode)),
		1024*1024,
	)
	require.NoError(t, err)
	return release
}

func TestAppReleaseAdminServiceDraftPublishAndPolicy(t *testing.T) {
	svc, db, admin := newAppReleaseAdminTestService(t)
	first := createAppReleaseDraftForTest(t, svc, admin, 1603, 1601)
	firstPath, err := svc.LocateAPK(first)
	require.NoError(t, err)
	_, err = os.Stat(firstPath)
	require.NoError(t, err)

	publishedFirst, err := svc.PublishDraft(context.Background(), first.ID, admin.ID)
	require.NoError(t, err)
	require.Equal(t, models.AppReleaseStatusPublished, publishedFirst.Status)
	require.NotNil(t, publishedFirst.PublishedAt)

	second := createAppReleaseDraftForTest(t, svc, admin, 1604, 1602)
	publishedSecond, err := svc.PublishDraft(context.Background(), second.ID, admin.ID)
	require.NoError(t, err)

	minimum := int64(1604)
	updated, err := svc.UpdateDraft(
		context.Background(),
		publishedSecond.ID,
		admin.ID,
		AppReleaseDraftUpdate{MinimumSupportedVersionCode: &minimum},
	)
	require.NoError(t, err)
	require.Equal(t, minimum, updated.MinimumSupportedVersionCode)

	oldMinimum := int64(1602)
	_, err = svc.UpdateDraft(
		context.Background(),
		publishedFirst.ID,
		admin.ID,
		AppReleaseDraftUpdate{MinimumSupportedVersionCode: &oldMinimum},
	)
	require.Error(t, err)
	require.True(t, errors.Is(err, ErrAppReleaseInvalid))

	var logCount int64
	require.NoError(t, db.Model(&models.AdminLog{}).Count(&logCount).Error)
	require.GreaterOrEqual(t, logCount, int64(5))
}

func TestAppReleaseAdminServiceDeleteDraftRemovesPrivateAPK(t *testing.T) {
	svc, db, admin := newAppReleaseAdminTestService(t)
	draft := createAppReleaseDraftForTest(t, svc, admin, 1603, 1601)
	path, err := svc.LocateAPK(draft)
	require.NoError(t, err)

	require.NoError(t, svc.DeleteDraft(context.Background(), draft.ID, admin.ID))
	_, err = os.Stat(path)
	require.True(t, os.IsNotExist(err))
	var count int64
	require.NoError(t, db.Model(&models.AppRelease{}).Count(&count).Error)
	require.Zero(t, count)
}

func TestAppReleaseAdminServiceOhosExternalMarketLifecycle(t *testing.T) {
	svc, db, admin := newAppReleaseAdminTestService(t)
	// Create a baseline release so we can withdraw the new one
	require.NoError(t, db.Create(&models.AppRelease{
		Platform:                    "ohos",
		Channel:                     "stable",
		VersionName:                 "1.6.0",
		VersionCode:                 1600,
		Title:                       "Baseline",
		Changelog:                   "Baseline",
		MinimumSupportedVersionCode: 1600,
		CreatedBy:                   admin.ID,
		DeliveryMode:                models.AppReleaseDeliveryModeExternalMarket,
		ActionURL:                   "https://example.com",
		Status:                      models.AppReleaseStatusPublished,
	}).Error)

	draft, err := svc.CreateDraft(context.Background(), AppReleaseDraftInput{
		Platform:                    "ohos",
		Channel:                     "stable",
		VersionName:                 "1.6.5",
		VersionCode:                 1605,
		Title:                       "HarmonyOS Update",
		Changelog:                   "Support HarmonyOS",
		MinimumSupportedVersionCode: 1600,
		CreatedBy:                   admin.ID,
		DeliveryMode:                models.AppReleaseDeliveryModeExternalMarket,
		ActionURL:                   "https://appgallery.huawei.com/",
	}, "", bytes.NewReader([]byte{}), 1024)
	require.NoError(t, err)
	require.Equal(t, "ohos", draft.Platform)
	require.Equal(t, models.AppReleaseDeliveryModeExternalMarket, draft.DeliveryMode)

	// Publish
	published, err := svc.PublishDraft(context.Background(), draft.ID, admin.ID)
	require.NoError(t, err)
	require.Equal(t, models.AppReleaseStatusPublished, published.Status)

	// Withdraw
	withdrawn, err := svc.WithdrawPublished(context.Background(), published.ID, admin.ID)
	require.NoError(t, err)
	require.Equal(t, models.AppReleaseStatusWithdrawn, withdrawn.Status)

	// Test DeleteDraft with a new draft
	draft2, err := svc.CreateDraft(context.Background(), AppReleaseDraftInput{
		Platform:                    "ohos",
		Channel:                     "stable",
		VersionName:                 "1.6.6",
		VersionCode:                 1606,
		Title:                       "Another Draft",
		Changelog:                   "...",
		MinimumSupportedVersionCode: 1600,
		CreatedBy:                   admin.ID,
		DeliveryMode:                models.AppReleaseDeliveryModeExternalMarket,
		ActionURL:                   "https://example.com/2",
	}, "", bytes.NewReader([]byte{}), 1024)
	require.NoError(t, err)

	// Delete Draft
	err = svc.DeleteDraft(context.Background(), draft2.ID, admin.ID)
	require.NoError(t, err)

	var count int64
	require.NoError(t, db.Model(&models.AppRelease{}).Where("id = ?", draft2.ID).Count(&count).Error)
	require.Zero(t, count)
}
