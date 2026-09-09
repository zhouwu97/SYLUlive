package services

import (
	"fmt"
	"testing"

	"shenliyuan/internal/models"

	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func newAccessScopeTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	db := newFileReferenceTestDB(t)
	for _, ddl := range []string{
		"CREATE TABLE canteen_dish_photos (id INTEGER PRIMARY KEY, file_id BIGINT, status TEXT)",
		"CREATE TABLE canteens (id INTEGER PRIMARY KEY, verified BOOLEAN, image TEXT)",
		"CREATE TABLE canteen_review_events (id INTEGER PRIMARY KEY, canteen_id BIGINT, status TEXT, images TEXT)",
		"CREATE TABLE canteen_ratings (id INTEGER PRIMARY KEY, canteen_id BIGINT, status TEXT, images TEXT)",
		"CREATE TABLE user_emoji_assets (id INTEGER PRIMARY KEY, file_id BIGINT)",
		"CREATE TABLE messages (id INTEGER PRIMARY KEY, file_id BIGINT)",
		"CREATE TABLE feedbacks (id INTEGER PRIMARY KEY, images TEXT)",
		"CREATE TABLE users (id INTEGER PRIMARY KEY, avatar TEXT, background TEXT)",
	} {
		require.NoError(t, db.Exec(ddl).Error)
	}
	return db
}

func TestMigrateFileAccessScopesPublicAndPrivateBoundaries(t *testing.T) {
	db := newAccessScopeTestDB(t)
	for id := 1; id <= 13; id++ {
		scope := models.FileAccessPrivate
		if id == 1 || id == 3 || id == 13 {
			scope = models.FileAccessPublic
		}
		require.NoError(t, db.Create(&models.File{ID: uint(id), Hash: fmt.Sprint(id), Path: fmt.Sprintf("/uploads/%d.jpg", id), MimeType: "image/jpeg", Status: "active", AccessScope: scope}).Error)
	}
	for _, sql := range []string{
		"UPDATE files SET status='temporary' WHERE id=1",
		"INSERT INTO canteen_dish_photos VALUES (1,1,'approved'),(2,2,'approved'),(3,3,'archived')",
		"INSERT INTO canteens VALUES (1,TRUE,'/uploads/4.jpg'),(2,FALSE,'/uploads/5.jpg')",
		`INSERT INTO canteen_review_events VALUES (1,1,'active','["https://sylulive.online/uploads/6.jpg?v=2"]'),(2,1,'hidden','["/uploads/7.jpg"]'),(3,2,'active','["/uploads/5.jpg"]'),(4,1,'active','["/uploads/13.jpg.extra","/uploads/other.jpg?ref=/uploads/13.jpg"]')`,
		"INSERT INTO user_emoji_assets VALUES (1,8)",
		"INSERT INTO messages VALUES (1,9)",
		`INSERT INTO feedbacks VALUES (1,'["/uploads/10.jpg"]')`,
		"INSERT INTO users VALUES (1,'/uploads/11.jpg?v=3','')",
		`INSERT INTO canteen_ratings VALUES (1,1,'active','["uploads/12.jpg"]')`,
	} {
		require.NoError(t, db.Exec(sql).Error)
	}
	require.NoError(t, MigrateFileAccessScopes(db))
	publicIDs := map[uint]bool{1: true, 2: true, 4: true, 6: true, 11: true, 12: true}
	var files []models.File
	require.NoError(t, db.Order("id").Find(&files).Error)
	for _, file := range files {
		want := models.FileAccessPrivate
		if publicIDs[file.ID] {
			want = models.FileAccessPublic
		}
		require.Equal(t, want, file.AccessScope, "file %d", file.ID)
		if file.ID == 1 {
			require.Equal(t, "active", file.Status)
			require.NotNil(t, file.ClaimedAt)
		}
	}
	// 首次迁移后出现新的合法状态，第二次启动不能重新洗权限。
	require.NoError(t, db.Exec("UPDATE files SET access_scope='private' WHERE id=2").Error)
	require.NoError(t, MigrateFileAccessScopes(db))
	var after models.File
	require.NoError(t, db.First(&after, 2).Error)
	require.Equal(t, models.FileAccessPrivate, after.AccessScope)
	var versions int64
	require.NoError(t, db.Model(&models.AppSchemaMigration{}).Where("version = ?", FileAccessScopeMigrationVersion).Count(&versions).Error)
	require.EqualValues(t, 1, versions)
}

func TestMigrateFileAccessScopesRollsBackOnFailure(t *testing.T) {
	db := newAccessScopeTestDB(t)
	for id := 1; id <= 2; id++ {
		require.NoError(t, db.Create(&models.File{ID: uint(id), Hash: fmt.Sprint(id), Path: fmt.Sprintf("/uploads/%d.jpg", id), Status: "active", AccessScope: models.FileAccessPrivate}).Error)
	}
	require.NoError(t, db.Exec("INSERT INTO canteen_dish_photos VALUES (1,1,'approved'),(2,2,'approved')").Error)
	require.NoError(t, db.Exec(`CREATE TRIGGER reject_scope BEFORE UPDATE ON files WHEN NEW.id=2 BEGIN SELECT RAISE(ABORT,'injected migration failure'); END`).Error)
	require.ErrorContains(t, MigrateFileAccessScopes(db), "injected migration failure")
	var changed, applied int64
	require.NoError(t, db.Model(&models.File{}).Where("access_scope='public'").Count(&changed).Error)
	require.Zero(t, changed)
	require.NoError(t, db.Model(&models.AppSchemaMigration{}).Count(&applied).Error)
	require.Zero(t, applied)
	require.NoError(t, db.Exec("DROP TRIGGER reject_scope").Error)
	require.NoError(t, MigrateFileAccessScopes(db))
}

func TestReconcilePublicAccessWaitsForLastReference(t *testing.T) {
	db := newAccessScopeTestDB(t)
	file := models.File{ID: 1, Hash: "shared", Path: "/uploads/shared.jpg", Status: "active", AccessScope: models.FileAccessPublic}
	require.NoError(t, db.Create(&file).Error)
	require.NoError(t, db.Exec("INSERT INTO canteen_dish_photos VALUES (1,1,'approved')").Error)
	require.NoError(t, db.Exec("INSERT INTO canteens VALUES (1,TRUE,'/uploads/shared.jpg')").Error)
	require.NoError(t, db.Exec("INSERT INTO user_emoji_assets VALUES (1,1)").Error)
	require.NoError(t, db.Exec("UPDATE canteen_dish_photos SET status='archived'").Error)
	require.NoError(t, ReconcileFilePublicAccess(db, file.ID))
	require.NoError(t, db.First(&file, file.ID).Error)
	require.Equal(t, models.FileAccessPublic, file.AccessScope)
	require.NoError(t, db.Exec("UPDATE canteens SET verified=FALSE").Error)
	require.NoError(t, ReconcileFilePublicAccess(db, file.ID))
	require.NoError(t, db.First(&file, file.ID).Error)
	require.Equal(t, models.FileAccessPrivate, file.AccessScope)
}
