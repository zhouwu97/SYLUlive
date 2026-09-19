package services

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newUploadProtectionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.File{}, &models.FileUploadGrant{}))
	require.NoError(t, db.Create(&models.User{PasswordHash: "test", Nickname: "quota-user"}).Error)
	return db
}

func TestUploadProtectionRejectsQuotaInsideTransaction(t *testing.T) {
	db := newUploadProtectionTestDB(t)
	policy := NewUploadProtection(db, t.TempDir(), UploadProtectionConfig{
		PerMinuteCountLimit:  1,
		HourlyBytesLimit:     100,
		TemporaryUserCount:   10,
		TemporaryUserBytes:   1000,
		TemporaryGlobalBytes: 1000,
	})
	now := time.Date(2026, 9, 20, 8, 0, 0, 0, time.UTC)
	require.NoError(t, db.Create(&models.File{
		Hash: "recent", Path: "/uploads/recent.png", Size: 20, MimeType: "image/png",
		UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate,
		CreatedAt: now.Add(-30 * time.Second),
	}).Error)

	err := db.Transaction(func(tx *gorm.DB) error {
		return policy.CheckQuota(tx, 1, 1, 20, now)
	})
	require.Error(t, err)
	require.True(t, errors.Is(err, ErrUploadQuotaExceeded), err)
}

func TestUploadProtectionPersistsTemporaryFileAtomically(t *testing.T) {
	db := newUploadProtectionTestDB(t)
	dir := t.TempDir()
	policy := NewUploadProtection(db, dir, UploadProtectionConfig{
		PerMinuteCountLimit:  10,
		HourlyBytesLimit:     1 << 20,
		TemporaryUserCount:   10,
		TemporaryUserBytes:   1 << 20,
		TemporaryGlobalBytes: 1 << 20,
	})
	policy.SetDiskUsageReader(func(string) (DiskUsageSnapshot, error) {
		return DiskUsageSnapshot{UsedPercent: 10}, nil
	})

	dst := filepath.Join(dir, "aa", "hash.png")
	record := &models.File{
		Hash: "hash", Path: "/uploads/aa/hash.png", Size: 4, MimeType: "image/png",
		UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate,
	}
	called := false
	result, err := policy.PersistTemporaryFile(t.Context(), record, func() error {
		called = true
		require.NoError(t, os.MkdirAll(filepath.Dir(dst), 0755))
		return os.WriteFile(dst, []byte("data"), 0644)
	})
	require.NoError(t, err)
	require.True(t, called)
	require.False(t, result.Reused)
	require.NotZero(t, result.File.ID)
	require.FileExists(t, dst)
	var grant models.FileUploadGrant
	require.NoError(t, db.Where("file_id = ? AND user_id = ?", result.File.ID, 1).First(&grant).Error)
}

func TestUploadProtectionStopsCriticalDiskBeforeWriting(t *testing.T) {
	db := newUploadProtectionTestDB(t)
	policy := NewUploadProtection(db, t.TempDir(), UploadProtectionConfig{
		PerMinuteCountLimit:  10,
		HourlyBytesLimit:     1 << 20,
		TemporaryUserCount:   10,
		TemporaryUserBytes:   1 << 20,
		TemporaryGlobalBytes: 1 << 20,
		DiskCriticalPercent:  90,
	})
	policy.SetDiskUsageReader(func(string) (DiskUsageSnapshot, error) {
		return DiskUsageSnapshot{UsedPercent: 95}, nil
	})

	called := false
	_, err := policy.PersistTemporaryFile(t.Context(), &models.File{
		Hash: "blocked", Path: "/uploads/blocked.png", Size: 4, MimeType: "image/png",
		UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate,
	}, func() error {
		called = true
		return nil
	})
	require.ErrorIs(t, err, ErrUploadStoragePressure)
	require.False(t, called)
}
