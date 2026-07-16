package services

import (
	"context"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func newAppReleaseTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AppRelease{}))
	return db
}

func TestDecideUpdate(t *testing.T) {
	cases := []struct {
		name     string
		current  int64
		latest   int64
		minimum  int64
		expected UpdateDecision
	}{
		{"equal latest", 1603, 1603, 1601, UpdateNone},
		{"above latest", 1604, 1603, 1601, UpdateNone},
		{"between minimum and latest", 1602, 1603, 1602, UpdateOptional},
		{"equal minimum but below latest", 1602, 1603, 1601, UpdateOptional},
		{"below minimum", 1601, 1603, 1602, UpdateRequired},
		{"minimum equal latest forces required for old", 1601, 1603, 1603, UpdateRequired},
		{"minimum equal latest no update for latest", 1603, 1603, 1603, UpdateNone},
		{"zero current is illegal", 0, 1603, 1601, UpdateNone},
		{"negative latest is illegal", 1601, -1, 1601, UpdateNone},
		{"zero minimum is illegal", 1602, 1603, 0, UpdateNone},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := DecideUpdate(tc.current, tc.latest, tc.minimum)
			require.Equal(t, tc.expected, got)
		})
	}
}

func TestGetLatestPublished_NoRows(t *testing.T) {
	db := newAppReleaseTestDB(t)
	svc := NewAppReleaseService(db, t.TempDir())
	_, err := svc.GetLatestPublished(context.Background(), models.AppReleasePlatformAndroid, models.AppReleaseChannelStable)
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
}

func TestGetLatestPublished_PicksHighestVersionCode(t *testing.T) {
	db := newAppReleaseTestDB(t)
	require.NoError(t, db.Create(buildReleasePtr(1601, models.AppReleaseStatusPublished)).Error)
	require.NoError(t, db.Create(buildReleasePtr(1602, models.AppReleaseStatusPublished)).Error)

	svc := NewAppReleaseService(db, t.TempDir())
	got, err := svc.GetLatestPublished(context.Background(), models.AppReleasePlatformAndroid, models.AppReleaseChannelStable)
	require.NoError(t, err)
	require.Equal(t, int64(1602), got.VersionCode)
}

func TestGetLatestPublished_IgnoresDraftAndWithdrawn(t *testing.T) {
	db := newAppReleaseTestDB(t)
	require.NoError(t, db.Create(buildReleasePtr(1601, models.AppReleaseStatusDraft)).Error)
	require.NoError(t, db.Create(buildReleasePtr(1602, models.AppReleaseStatusWithdrawn)).Error)

	svc := NewAppReleaseService(db, t.TempDir())
	_, err := svc.GetLatestPublished(context.Background(), models.AppReleasePlatformAndroid, models.AppReleaseChannelStable)
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
}

func TestGetLatestPublished_RejectsEmptyPlatformOrChannel(t *testing.T) {
	db := newAppReleaseTestDB(t)
	svc := NewAppReleaseService(db, t.TempDir())
	_, err := svc.GetLatestPublished(context.Background(), "", models.AppReleaseChannelStable)
	require.Error(t, err)
	_, err = svc.GetLatestPublished(context.Background(), models.AppReleasePlatformAndroid, "")
	require.Error(t, err)
}

func TestLocateAPK_RejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	svc := NewAppReleaseService(nil, dir)

	cases := []struct {
		name string
		key  string
	}{
		{"absolute", "/etc/passwd"},
		{"dotdot parent", "../etc/passwd"},
		{"embedded dotdot segment", "android/stable/../../etc/passwd"},
		{"backslash escapes via Windows path", `android\..\..\etc`},
		{"empty", ""},
		{"null byte", "android/stable\u0000/evil.apk"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			release := &models.AppRelease{StorageKey: tc.key}
			_, err := svc.LocateAPK(release)
			require.Error(t, err, "expected rejection for key %q", tc.key)
		})
	}
}

func TestLocateAPK_BuildsValidPath(t *testing.T) {
	dir := t.TempDir()
	svc := NewAppReleaseService(nil, dir)
	release := &models.AppRelease{StorageKey: "android/stable/1602/shenliyuan-1602.apk"}
	got, err := svc.LocateAPK(release)
	require.NoError(t, err)
	require.True(t, strings.HasSuffix(filepath.ToSlash(got), "android/stable/1602/shenliyuan-1602.apk"))
}

// buildReleasePtr 创建一个最小可写入数据库的 AppRelease 并返回指针。
// gorm 需要可寻址的指针才能在 Create 回填主键，函数返回值本身不可寻址。
func buildReleasePtr(versionCode int64, status string) *models.AppRelease {
	r := models.AppRelease{
		Platform:                    models.AppReleasePlatformAndroid,
		Channel:                     models.AppReleaseChannelStable,
		VersionName:                 "1.6.x",
		VersionCode:                 versionCode,
		Title:                       "test",
		Changelog:                   "test",
		MinimumSupportedVersionCode: 1601,
		FileName:                    "shenliyuan.apk",
		StorageKey:                  "android/stable/" + strconv.FormatInt(versionCode, 10) + "/shenliyuan.apk",
		FileSize:                    1,
		SHA256:                      "0000000000000000000000000000000000000000000000000000000000000000",
		Status:                      status,
	}
	return &r
}
