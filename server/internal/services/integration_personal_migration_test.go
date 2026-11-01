package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/datatypes"
	"gorm.io/gorm/clause"
	"shenliyuan/internal/models"
)

func TestIntegrationPersonalLegacySQLConstraintMigration(t *testing.T) {
	db := integrationTestDB(t)
	if db.Dialector.Name() != "postgres" {
		t.Skip("历史SQL约束迁移需要专用PostgreSQL，SQLite不能代替")
	}
	integrationTestUser(t, db, 1)
	legacy, err := os.ReadFile("../../sql/20260725_personal_uploaded_snapshots.sql")
	require.NoError(t, err)
	require.NoError(t, db.Exec(string(legacy)).Error)
	require.NoError(t, db.AutoMigrate(&models.AIUserPermission{}))
	now := time.Now()
	payload, _, err := normalizeErkeSnapshotUpload(validErkeSnapshotUpload(now))
	require.NoError(t, err)
	legacyHash := sha256.Sum256(payload)
	old := models.PersonalUploadedSnapshot{UserID: 1, SnapshotType: "erke", SchemaVersion: 2, PayloadJSON: datatypes.JSON(payload), PayloadHash: hex.EncodeToString(legacyHash[:]), FetchedAt: now, ExpiresAt: now.Add(time.Hour)}
	require.NoError(t, db.Create(&old).Error)
	auth := NewIntegrationAuthService(db)
	upload := IntegrationGradesUpload{Consent: true, FetchedAt: now, Year: "2026", Semester: 3, Grades: []IntegrationGrade{{CourseName: "合成迁移课程", Score: "合格", Credits: 2}}}
	err = auth.StoreUploadedGrades(context.Background(), 1, upload)
	require.ErrorContains(t, err, "chk_personal_uploaded_snapshots_type", "证明旧迁移实际阻止新类型")
	migration, err := os.ReadFile("../../sql/20261101_integration_personal_snapshots.sql")
	require.NoError(t, err)
	for range 2 {
		require.NoError(t, db.Exec(string(migration)).Error)
	}
	require.NoError(t, auth.StoreUploadedGrades(context.Background(), 1, upload))
	var previous models.PersonalUploadedSnapshot
	require.NoError(t, db.First(&previous, old.ID).Error)
	require.Equal(t, old.PayloadHash, previous.PayloadHash)
	require.JSONEq(t, string(old.PayloadJSON), string(previous.PayloadJSON))
	lookup, err := NewPersonalSnapshotService(db, time.Now).LookupErke(context.Background(), 1)
	require.NoError(t, err, "真实jsonb重排后旧版哈希仍可验证")
	require.True(t, lookup.Found)
	invalid := old
	invalid.ID = 0
	invalid.SnapshotType = "arbitrary_private_data"
	require.Error(t, db.Create(&invalid).Error, "扩展类型后仍拒绝未知私有资料类型")
}

func TestIntegrationPersonalPostgresReadWaitsForRevocation(t *testing.T) {
	if os.Getenv("INTEGRATION_TEST_POSTGRES_DSN") == "" {
		t.Skip("行锁时序需要专用PostgreSQL")
	}
	db, auth, binding, _ := personalIntegrationFixture(t)
	tx := db.Begin()
	require.NoError(t, tx.Error)
	defer tx.Rollback()
	var owner models.User
	require.NoError(t, tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).First(&owner, binding.OwnerID).Error)
	var holder int
	require.NoError(t, tx.Raw("SELECT pg_backend_pid()").Scan(&holder).Error)
	type answer struct {
		data map[string]interface{}
		err  error
	}
	done := make(chan answer, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go func() {
		data, err := auth.ReadPersonal(ctx, binding, "grades", 0, 20)
		done <- answer{data, err}
	}()
	require.Eventually(t, func() bool {
		var count int64
		err := db.Raw("SELECT count(*) FROM pg_stat_activity WHERE ? = ANY(pg_blocking_pids(pid))", holder).Scan(&count).Error
		return err == nil && count > 0
	}, 5*time.Second, 10*time.Millisecond, "真实读取必须等待用户行上的撤权事务")
	require.NoError(t, tx.Model(&models.IntegrationBinding{}).Where("id = ?", binding.ID).Updates(map[string]interface{}{"state": "revoked", "epoch": binding.Epoch + 1}).Error)
	require.NoError(t, tx.Commit().Error)
	select {
	case result := <-done:
		require.Error(t, result.err)
		require.Nil(t, result.data, "等待中的请求不能在撤权提交后返回旧正文")
	case <-ctx.Done():
		t.Fatal("撤权后读取未及时结束")
	}
}
