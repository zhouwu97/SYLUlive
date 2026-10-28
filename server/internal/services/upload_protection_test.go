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

func TestUploadProtectionRemovesPhysicalFileWhenTransactionFails(t *testing.T) {
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
	secondPath := filepath.Join(dir, "bb", "failed-callback.png")
	_, err := policy.PersistTemporaryFile(t.Context(), &models.File{
		Hash: "failed-callback", Path: "/uploads/bb/failed-callback.png", Size: 1, MimeType: "image/png",
		UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate,
	}, func() error {
		require.NoError(t, os.MkdirAll(filepath.Dir(secondPath), 0755))
		require.NoError(t, os.WriteFile(secondPath, []byte("x"), 0644))
		return errors.New("模拟写入失败")
	})
	require.Error(t, err)
	require.NoFileExists(t, secondPath)
}

func TestUploadProtectionReusesOrRestoresExistingFileUnderRowLock(t *testing.T) {
	db := newUploadProtectionTestDB(t)
	dir := t.TempDir()
	policy := NewUploadProtection(db, dir, UploadProtectionConfig{})
	policy.SetDiskUsageReader(func(string) (DiskUsageSnapshot, error) {
		return DiskUsageSnapshot{UsedPercent: 10}, nil
	})
	existing := models.File{
		Hash: "restore-existing", Path: "/uploads/aa/restore-existing.png", Size: 1,
		MimeType: "image/png", UploaderID: 1, Status: models.FileStatusTemporary,
		AccessScope: models.FileAccessPrivate,
	}
	require.NoError(t, db.Create(&existing).Error)
	var written string
	result, found, err := policy.ReuseOrRestoreFile(t.Context(), &models.File{
		Hash: "restore-existing", Path: "/uploads/ignored.png", Size: 4,
		MimeType: "image/jpeg", Width: 10, Height: 20, UploaderID: 1,
	}, func(path string) error {
		written = path
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0755))
		return os.WriteFile(path, []byte("data"), 0644)
	})
	require.NoError(t, err)
	require.True(t, found)
	require.False(t, result.Reused)
	require.Equal(t, existing.ID, result.File.ID)
	require.Equal(t, filepath.Join(dir, "aa", "restore-existing.png"), written)
	require.FileExists(t, written)
	var updated models.File
	require.NoError(t, db.First(&updated, existing.ID).Error)
	require.Equal(t, int64(4), updated.Size)
	require.Equal(t, "image/jpeg", updated.MimeType)
	var grant models.FileUploadGrant
	require.NoError(t, db.Where("file_id = ? AND user_id = ?", existing.ID, 1).First(&grant).Error)
}

func TestUploadProtectionRejectsReuseWhileFileIsDeleting(t *testing.T) {
	db := newUploadProtectionTestDB(t)
	policy := NewUploadProtection(db, t.TempDir(), UploadProtectionConfig{})
	file := models.File{
		Hash: "reuse-deleting", Path: "/uploads/reuse-deleting.png", Size: 1,
		MimeType: "image/png", UploaderID: 1, Status: models.FileStatusDeleting,
		AccessScope: models.FileAccessPrivate,
	}
	require.NoError(t, db.Create(&file).Error)
	_, found, err := policy.ReuseOrRestoreFile(t.Context(), &models.File{
		Hash: "reuse-deleting", UploaderID: 1,
	}, func(string) error { return nil })
	require.True(t, found)
	require.ErrorIs(t, err, ErrFileBeingDeleted)
}

func TestUploadProtectionRepeatedUploadRefreshesOnlyCurrentUsersRetention(t *testing.T) {
	for _, method := range []string{"persist-reused", "reuse-present", "restore-missing"} {
		t.Run(method, func(t *testing.T) {
			db := newUploadProtectionTestDB(t)
			dir := t.TempDir()
			now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
			old := now.Add(-7 * time.Hour)
			file := models.File{
				Hash: "renew-retention", Path: "/uploads/renew.png", Size: 4, MimeType: "image/png",
				UploaderID: 1, Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate,
				CreatedAt: old,
			}
			require.NoError(t, db.Create(&file).Error)
			for _, userID := range []uint{1, 2} {
				require.NoError(t, db.Create(&models.FileUploadGrant{FileID: file.ID, UserID: userID, CreatedAt: old}).Error)
			}
			path := filepath.Join(dir, "renew.png")
			if method != "restore-missing" {
				require.NoError(t, os.WriteFile(path, []byte("data"), 0o600))
			}
			policy := NewUploadProtection(db, dir, UploadProtectionConfig{})
			policy.SetNow(func() time.Time { return now })
			policy.SetDiskUsageReader(func(string) (DiskUsageSnapshot, error) {
				return DiskUsageSnapshot{UsedPercent: 10}, nil
			})
			reupload := &models.File{Hash: file.Hash, UploaderID: 1, Size: 4, MimeType: file.MimeType}
			if method == "persist-reused" {
				_, err := policy.PersistTemporaryFile(t.Context(), reupload, func() error {
					t.Fatal("复用已有文件不应重写原图")
					return nil
				})
				require.NoError(t, err)
			} else {
				_, found, err := policy.ReuseOrRestoreFile(t.Context(), reupload, func(path string) error {
					return os.WriteFile(path, []byte("data"), 0o600)
				})
				require.NoError(t, err)
				require.True(t, found)
			}
			var grants []models.FileUploadGrant
			require.NoError(t, db.Where("file_id = ?", file.ID).Order("user_id ASC").Find(&grants).Error)
			require.Len(t, grants, 2)
			require.WithinDuration(t, now, grants[0].CreatedAt, time.Millisecond)
			require.WithinDuration(t, old, grants[1].CreatedAt, time.Millisecond)
			var kept models.File
			require.NoError(t, db.First(&kept, file.ID).Error)
			require.WithinDuration(t, old, kept.CreatedAt, time.Millisecond)
			require.Equal(t, models.FileStatusTemporary, kept.Status)
			require.Equal(t, models.FileAccessPrivate, kept.AccessScope)

			janitor := NewTemporaryFileJanitor(db, dir, TemporaryFileJanitorConfig{TTL: time.Hour, BatchSize: 10})
			janitor.SetNow(func() time.Time { return now.Add(10 * time.Minute) })
			report, err := janitor.Run(t.Context())
			require.NoError(t, err)
			require.Equal(t, 1, report.RetainedRecentGrant)
			require.FileExists(t, path)
			// 没有再次上传时，刷新过的窗口到期后仍正常回收，不形成永久垃圾。
			janitor.SetNow(func() time.Time { return now.Add(70 * time.Minute) })
			report, err = janitor.Run(t.Context())
			require.NoError(t, err)
			require.Equal(t, 1, report.Removed)
			require.NoFileExists(t, path)
		})
	}
}

func TestUploadProtectionRejectedDeletingFileDoesNotRenewGrant(t *testing.T) {
	db := newUploadProtectionTestDB(t)
	now := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	old := now.Add(-7 * time.Hour)
	file := models.File{
		Hash: "deleting-no-renew", Path: "/uploads/deleting-no-renew.png", Size: 4, MimeType: "image/png",
		UploaderID: 1, Status: models.FileStatusDeleting, AccessScope: models.FileAccessPrivate, CreatedAt: old,
	}
	require.NoError(t, db.Create(&file).Error)
	require.NoError(t, db.Create(&models.FileUploadGrant{FileID: file.ID, UserID: 1, CreatedAt: old}).Error)
	policy := NewUploadProtection(db, t.TempDir(), UploadProtectionConfig{})
	policy.SetNow(func() time.Time { return now })
	reupload := &models.File{Hash: file.Hash, UploaderID: 1}
	_, err := policy.PersistTemporaryFile(t.Context(), reupload, func() error { return nil })
	require.ErrorIs(t, err, ErrFileBeingDeleted)
	_, _, err = policy.ReuseOrRestoreFile(t.Context(), reupload, func(string) error { return nil })
	require.ErrorIs(t, err, ErrFileBeingDeleted)
	var grant models.FileUploadGrant
	require.NoError(t, db.Where("file_id = ? AND user_id = ?", file.ID, 1).First(&grant).Error)
	require.WithinDuration(t, old, grant.CreatedAt, time.Millisecond)
}
