package models

import (
	"path/filepath"
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestCompetitionAwardMigrationPreservesExistingEvents(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "competition-award.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(&CompetitionCategory{}, &CompetitionEvent{}); err != nil {
		t.Fatal(err)
	}
	event := CompetitionEvent{Title: "迁移前赛事", Status: "published", CompetitionRating: "A"}
	if err := db.Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&UserCompetitionAward{}); err != nil {
		t.Fatal(err)
	}
	var persisted CompetitionEvent
	if err := db.First(&persisted, event.ID).Error; err != nil {
		t.Fatal(err)
	}
	if persisted.Title != event.Title || persisted.CompetitionRating != event.CompetitionRating {
		t.Fatalf("existing event changed after migration: %+v", persisted)
	}
	if !db.Migrator().HasTable(&UserCompetitionAward{}) {
		t.Fatal("user competition awards table was not created")
	}
}
