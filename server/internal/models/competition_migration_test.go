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
	"gorm.io/gorm/clause"
)

func TestCompetitionCalendarDedupMigrationKeepsDeterministicWinner(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "competition.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&UserCompetitionCalendarItem{}); err != nil {
		t.Fatal(err)
	}
	eventID := uint(9)
	old := time.Now().Add(-time.Hour)
	items := []UserCompetitionCalendarItem{
		{UserID: 1, CalendarID: 1, Title: "普通", SourceType: "official", SourceEventID: &eventID, UpdatedAt: time.Now()},
		{UserID: 1, CalendarID: 1, Title: "置顶", SourceType: "official", SourceEventID: &eventID, IsPinned: true, UpdatedAt: old},
		{UserID: 1, CalendarID: 1, Title: "已修改", SourceType: "official", SourceEventID: &eventID, IsCustomModified: true, UpdatedAt: old},
	}
	for index := range items {
		if err := db.Create(&items[index]).Error; err != nil {
			t.Fatal(err)
		}
	}
	report, err := ApplyCompetitionCalendarDedupMigration(db)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Applied || report.DuplicateRows != 2 || report.Groups[0].KeepID != items[2].ID {
		t.Fatalf("unexpected report: %+v", report)
	}
	var active []UserCompetitionCalendarItem
	if err := db.Find(&active).Error; err != nil {
		t.Fatal(err)
	}
	if len(active) != 1 || active[0].ID != items[2].ID {
		t.Fatalf("unexpected active rows: %+v", active)
	}
	duplicate := UserCompetitionCalendarItem{UserID: 1, CalendarID: 1, Title: "重复", SourceType: "official", SourceEventID: &eventID}
	if err := db.Create(&duplicate).Error; err == nil {
		t.Fatal("expected active official duplicate to violate unique index")
	}
	manualA := UserCompetitionCalendarItem{UserID: 1, CalendarID: 1, Title: "手动", SourceType: "manual"}
	manualB := UserCompetitionCalendarItem{UserID: 1, CalendarID: 1, Title: "手动", SourceType: "manual"}
	if err := db.Create(&manualA).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&manualB).Error; err != nil {
		t.Fatal(err)
	}
	if err := VerifyCompetitionCalendarDedupMigration(db); err != nil {
		t.Fatal(err)
	}
}

func TestCompetitionCalendarUniqueIndexPostgres(t *testing.T) {
	dsn := os.Getenv("TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("TEST_POSTGRES_DSN 未配置，跳过真实 PostgreSQL 集成测试")
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
	schema := fmt.Sprintf("competition_test_%d", time.Now().UnixNano())
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
	if err := db.AutoMigrate(&UserCompetitionCalendarItem{}); err != nil {
		t.Fatal(err)
	}
	if _, err := ApplyCompetitionCalendarDedupMigration(db); err != nil {
		t.Fatal(err)
	}
	eventID := uint(7)
	first := UserCompetitionCalendarItem{UserID: 1, CalendarID: 1, Title: "首次", SourceType: "official", SourceEventID: &eventID}
	if err := db.Create(&first).Error; err != nil {
		t.Fatal(err)
	}
	second := UserCompetitionCalendarItem{UserID: 1, CalendarID: 1, Title: "重复", SourceType: "official", SourceEventID: &eventID}
	result := db.Clauses(clause.OnConflict{DoNothing: true}).Create(&second)
	if result.Error != nil || result.RowsAffected != 0 {
		t.Fatalf("error=%v rows=%d", result.Error, result.RowsAffected)
	}
}
