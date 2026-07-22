package models

import (
	"encoding/json"
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
	if err := db.AutoMigrate(
		&UserCompetitionAward{},
		&CompetitionAwardVerificationLog{},
		&CompetitionAwardEvidence{},
		&CompetitionAwardEvidenceAccessLog{},
	); err != nil {
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
	for _, model := range []interface{}{
		&CompetitionAwardVerificationLog{},
		&CompetitionAwardEvidence{},
		&CompetitionAwardEvidenceAccessLog{},
	} {
		if !db.Migrator().HasTable(model) {
			t.Fatalf("verification table for %T was not created", model)
		}
	}
	for _, field := range []string{"UserID", "CompetitionEventID", "DeletedAt"} {
		if !db.Migrator().HasIndex(&UserCompetitionAward{}, field) {
			t.Fatalf("user competition award index missing: %s", field)
		}
	}
	fileIDs, _ := json.Marshal([]uint{11, 12})
	legacy := UserCompetitionAward{
		UserID: 1, CompetitionTitle: "历史赛事", CompetitionYear: 2025,
		AwardName: "二等奖", CompetitionStage: "provincial", Role: "member",
		SkillTags: []byte("[]"), EvidenceFileIDs: fileIDs,
		VerificationStatus: "self_reported", Visibility: "private",
	}
	if err := db.Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	if err := BackfillCompetitionAwardEvidence(db); err != nil {
		t.Fatal(err)
	}
	if err := BackfillCompetitionAwardEvidence(db); err != nil {
		t.Fatal(err)
	}
	var mappingCount int64
	if err := db.Model(&CompetitionAwardEvidence{}).Where("award_id = ?", legacy.ID).Count(&mappingCount).Error; err != nil || mappingCount != 2 {
		t.Fatalf("legacy evidence mapping count=%d err=%v", mappingCount, err)
	}
}
