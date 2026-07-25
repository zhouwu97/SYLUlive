package services

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

func newPersonalSnapshotTestService(t *testing.T, now time.Time) (*gorm.DB, *PersonalSnapshotService) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}, &models.PersonalUploadedSnapshot{}))
	require.NoError(t, db.Create(&models.User{ID: 1, StudentID: "snapshot-user", PasswordHash: "test"}).Error)
	return db, NewPersonalSnapshotService(db, func() time.Time { return now })
}

func validErkeSnapshotUpload(fetchedAt time.Time) ErkeSnapshotUpload {
	return ErkeSnapshotUpload{
		SchemaVersion: 2,
		FetchedAt:     fetchedAt,
		Graduation:    json.RawMessage(`{"earned_total":42.5,"required_total":60}`),
		Yearly:        json.RawMessage(`{"year":"2025-2026","earned_total":12}`),
		RecentActivities: json.RawMessage(`[
			{"name":"志愿服务","credits":1.5}
		]`),
	}
}

func TestPersonalSnapshotServiceStoresErkeWithoutCredentials(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newPersonalSnapshotTestService(t, now)
	result, err := service.StoreErke(context.Background(), 1, validErkeSnapshotUpload(now.Add(-time.Hour)))
	require.NoError(t, err)
	require.Equal(t, academic.DataSourceUserUploadedSnapshot, result.Source)
	require.Equal(t, academic.DataStatusAvailable, result.Status)
	require.False(t, result.IsPartial)

	var stored models.PersonalUploadedSnapshot
	require.NoError(t, db.First(&stored, "user_id = ? AND snapshot_type = ?", 1, PersonalSnapshotTypeErke).Error)
	require.Len(t, stored.PayloadHash, 64)
	require.NotContains(t, string(stored.PayloadJSON), "password")
	require.NotContains(t, string(stored.PayloadJSON), "cookie")

	lookup, err := service.LookupErke(context.Background(), 1)
	require.NoError(t, err)
	require.True(t, lookup.Found)
	require.Equal(t, academic.DatasetErke, lookup.Result.Evidence[0].Dataset)
}

func TestPersonalSnapshotServiceRejectsSensitiveFieldsAndKeepsExistingSnapshot(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	db, service := newPersonalSnapshotTestService(t, now)
	_, err := service.StoreErke(context.Background(), 1, validErkeSnapshotUpload(now))
	require.NoError(t, err)
	var before models.PersonalUploadedSnapshot
	require.NoError(t, db.First(&before, "user_id = ?", 1).Error)

	invalid := validErkeSnapshotUpload(now)
	invalid.RecentActivities = json.RawMessage(`[{"name":"bad","cookie":"secret"}]`)
	_, err = service.StoreErke(context.Background(), 1, invalid)
	require.ErrorIs(t, err, ErrInvalidPersonalSnapshot)

	var after models.PersonalUploadedSnapshot
	require.NoError(t, db.First(&after, "user_id = ?", 1).Error)
	require.Equal(t, before.PayloadHash, after.PayloadHash)
}

func TestPersonalSnapshotServiceMarksExpiredErkeSnapshotAsStaleAndDeletesIt(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	_, writer := newPersonalSnapshotTestService(t, now)
	_, err := writer.StoreErke(context.Background(), 1, validErkeSnapshotUpload(now))
	require.NoError(t, err)

	staleReader := NewPersonalSnapshotService(writer.db, func() time.Time { return now.Add(6 * 24 * time.Hour) })
	lookup, err := staleReader.LookupErke(context.Background(), 1)
	require.NoError(t, err)
	require.True(t, lookup.Result.IsStale)
	require.Equal(t, academic.DataStatusStale, lookup.Result.Status)

	require.NoError(t, writer.DeleteErke(context.Background(), 1))
	lookup, err = writer.LookupErke(context.Background(), 1)
	require.NoError(t, err)
	require.False(t, lookup.Found)
}
