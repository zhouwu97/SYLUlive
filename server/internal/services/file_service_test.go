package services

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"github.com/stretchr/testify/require"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newFileServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "test.db")), &gorm.Config{})
	require.NoError(t, err)
	t.Cleanup(func() {
		if sqlDB, closeErr := db.DB(); closeErr == nil {
			_ = sqlDB.Close()
		}
	})
	require.NoError(t, db.AutoMigrate(&models.File{}))
	return db
}

func newFileServiceTestRecord(t *testing.T, db *gorm.DB, hash, path string, refCount int) models.File {
	t.Helper()
	record := models.File{
		Hash: hash, Path: path, Size: 4, MimeType: "image/png",
		Status: models.FileStatusTemporary, AccessScope: models.FileAccessPrivate, RefCount: refCount,
	}
	require.NoError(t, db.Create(&record).Error)
	return record
}

func TestDeleteFileRemovesPhysicalFileAndRecord(t *testing.T) {
	db := newFileServiceTestDB(t)
	dir := t.TempDir()
	service := NewFileService(db, dir)

	diskPath := filepath.Join(dir, "ab", "hash-golden.png")
	require.NoError(t, os.MkdirAll(filepath.Dir(diskPath), 0755))
	require.NoError(t, os.WriteFile(diskPath, []byte("data"), 0644))
	record := newFileServiceTestRecord(t, db, "hash-golden", "/uploads/ab/hash-golden.png", 1)

	require.NoError(t, service.DeleteFile(record.ID))
	require.NoFileExists(t, diskPath)

	var count int64
	require.NoError(t, db.Model(&models.File{}).Where("id = ?", record.ID).Count(&count).Error)
	require.Zero(t, count)
}

func TestDeleteFileTreatsMissingPhysicalFileAsDeleted(t *testing.T) {
	db := newFileServiceTestDB(t)
	service := NewFileService(db, t.TempDir())
	record := newFileServiceTestRecord(t, db, "hash-missing", "/uploads/cd/hash-missing.png", 1)

	require.NoError(t, service.DeleteFile(record.ID))

	var count int64
	require.NoError(t, db.Model(&models.File{}).Where("id = ?", record.ID).Count(&count).Error)
	require.Zero(t, count)
}

func TestDeleteFileKeepsRecordWhenPhysicalRemovalFails(t *testing.T) {
	db := newFileServiceTestDB(t)
	dir := t.TempDir()
	service := NewFileService(db, dir)

	// 非空目录让 os.Remove 返回非 ErrNotExist 错误，稳定复现物理删除失败。
	diskPath := filepath.Join(dir, "ef", "hash-fail.png")
	require.NoError(t, os.MkdirAll(filepath.Join(diskPath, "child"), 0755))
	record := newFileServiceTestRecord(t, db, "hash-fail", "/uploads/ef/hash-fail.png", 1)

	require.Error(t, service.DeleteFile(record.ID))

	var stored models.File
	require.NoError(t, db.First(&stored, record.ID).Error)
	require.Equal(t, 1, stored.RefCount)
}

func TestDeleteFileDecrementsRefCountWithoutPhysicalRemoval(t *testing.T) {
	db := newFileServiceTestDB(t)
	dir := t.TempDir()
	service := NewFileService(db, dir)

	diskPath := filepath.Join(dir, "ab", "hash-shared.png")
	require.NoError(t, os.MkdirAll(filepath.Dir(diskPath), 0755))
	require.NoError(t, os.WriteFile(diskPath, []byte("data"), 0644))
	record := newFileServiceTestRecord(t, db, "hash-shared", "/uploads/ab/hash-shared.png", 2)

	require.NoError(t, service.DeleteFile(record.ID))

	var stored models.File
	require.NoError(t, db.First(&stored, record.ID).Error)
	require.Equal(t, 1, stored.RefCount)
	require.FileExists(t, diskPath)
}

func TestDeleteFileRejectsInvalidPathAndKeepsRecord(t *testing.T) {
	db := newFileServiceTestDB(t)
	service := NewFileService(db, t.TempDir())
	record := newFileServiceTestRecord(t, db, "hash-escape", "/uploads/../escape.png", 1)

	require.ErrorIs(t, service.DeleteFile(record.ID), ErrInvalidImageFileReference)

	var stored models.File
	require.NoError(t, db.First(&stored, record.ID).Error)
	require.Equal(t, 1, stored.RefCount)
}

func TestDeleteFileResolvesLegacyRelativeUploadPath(t *testing.T) {
	db := newFileServiceTestDB(t)
	dir := t.TempDir()
	service := NewFileService(db, dir)

	diskPath := filepath.Join(dir, "cd", "hash-legacy.png")
	require.NoError(t, os.MkdirAll(filepath.Dir(diskPath), 0755))
	require.NoError(t, os.WriteFile(diskPath, []byte("data"), 0644))
	record := newFileServiceTestRecord(t, db, "hash-legacy", "uploads/cd/hash-legacy.png", 1)

	require.NoError(t, service.DeleteFile(record.ID))
	require.NoFileExists(t, diskPath)
}
