package models

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func TestEnsureWaterTeamSchemaRecountsAcceptedApplications(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "team-schema.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	createMinimalWaterTeamSchema(t, db)
	seedMismatchedWaterTeamCounts(t, db)

	if err := EnsureWaterTeamSchema(db); err != nil {
		t.Fatal(err)
	}
	assertWaterTeamCounts(t, db, 3, 3)
	assertWaterTeamState(t, db, 2, 1, 3, RecruitmentStatusRecruiting)
	assertWaterTeamState(t, db, 3, 0, 3, RecruitmentStatusClosed)
}

func TestEnsureWaterTeamSchemaPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN 未配置，跳过真实 PostgreSQL 组队迁移测试")
	}
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	sqlDB.SetMaxOpenConns(1)
	defer sqlDB.Close()
	schema := fmt.Sprintf("water_team_test_%d", time.Now().UnixNano())
	if err := db.Exec("CREATE SCHEMA " + schema).Error; err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = db.Exec("SET search_path TO public").Error
		_ = db.Exec("DROP SCHEMA IF EXISTS " + schema + " CASCADE").Error
	}()
	if err := db.Exec("SET search_path TO " + schema).Error; err != nil {
		t.Fatal(err)
	}
	createMinimalWaterTeamSchema(t, db)
	seedMismatchedWaterTeamCounts(t, db)

	if err := EnsureWaterTeamSchema(db); err != nil {
		t.Fatal(err)
	}
	assertWaterTeamCounts(t, db, 3, 3)
	assertWaterTeamState(t, db, 2, 1, 3, RecruitmentStatusRecruiting)
	assertWaterTeamState(t, db, 3, 0, 3, RecruitmentStatusClosed)
	if err := db.Exec("UPDATE water_team_recruitments SET needed_count = 2 WHERE id = 1").Error; err == nil {
		t.Fatal("expected capacity CHECK constraint to reject needed_count below accepted_count")
	}
	if err := db.Exec("INSERT INTO notifications(id, user_id, type, dedup_key) VALUES (1, 1, 'team_application', 'same')").Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("INSERT INTO notifications(id, user_id, type, dedup_key) VALUES (2, 1, 'team_application', 'same')").Error; err == nil {
		t.Fatal("expected notification dedup unique index to reject duplicate event")
	}
}

func createMinimalWaterTeamSchema(t *testing.T, db *gorm.DB) {
	t.Helper()
	statements := []string{
		"CREATE TABLE water_section_tags (id INTEGER PRIMARY KEY, section_id INTEGER NOT NULL, content_mode VARCHAR(50) NOT NULL)",
		"CREATE TABLE notifications (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, type VARCHAR(50) NOT NULL, dedup_key VARCHAR(191) NOT NULL DEFAULT '')",
		"CREATE TABLE water_team_recruitments (id INTEGER PRIMARY KEY, needed_count INTEGER NOT NULL, accepted_count INTEGER NOT NULL, status VARCHAR(32) NOT NULL)",
		"CREATE TABLE water_team_applications (id INTEGER PRIMARY KEY, recruitment_id INTEGER NOT NULL, status VARCHAR(32) NOT NULL)",
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			t.Fatal(err)
		}
	}
}

func seedMismatchedWaterTeamCounts(t *testing.T, db *gorm.DB) {
	t.Helper()
	if err := db.Exec("INSERT INTO water_team_recruitments(id, needed_count, accepted_count, status) VALUES (1, 2, 1, 'recruiting'), (2, 3, 3, 'full'), (3, 3, 3, 'closed')").Error; err != nil {
		t.Fatal(err)
	}
	for id := 1; id <= 3; id++ {
		if err := db.Exec("INSERT INTO water_team_applications(id, recruitment_id, status) VALUES (?, 1, 'accepted')", id).Error; err != nil {
			t.Fatal(err)
		}
	}
	if err := db.Exec("INSERT INTO water_team_applications(id, recruitment_id, status) VALUES (4, 2, 'accepted')").Error; err != nil {
		t.Fatal(err)
	}
}

func assertWaterTeamState(t *testing.T, db *gorm.DB, id, accepted, needed int, status string) {
	t.Helper()
	var row struct {
		AcceptedCount int
		NeededCount   int
		Status        string
	}
	if err := db.Raw("SELECT accepted_count, needed_count, status FROM water_team_recruitments WHERE id = ?", id).Scan(&row).Error; err != nil {
		t.Fatal(err)
	}
	if row.AcceptedCount != accepted || row.NeededCount != needed || row.Status != status {
		t.Fatalf("id=%d accepted_count=%d needed_count=%d status=%s, want %d/%d/%s", id, row.AcceptedCount, row.NeededCount, row.Status, accepted, needed, status)
	}
}

func assertWaterTeamCounts(t *testing.T, db *gorm.DB, accepted, needed int) {
	t.Helper()
	var row struct {
		AcceptedCount int
		NeededCount   int
	}
	if err := db.Raw("SELECT accepted_count, needed_count FROM water_team_recruitments WHERE id = 1").Scan(&row).Error; err != nil {
		t.Fatal(err)
	}
	if row.AcceptedCount != accepted || row.NeededCount != needed {
		t.Fatalf("accepted_count=%d needed_count=%d, want %d/%d", row.AcceptedCount, row.NeededCount, accepted, needed)
	}
}
