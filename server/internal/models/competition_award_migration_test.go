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
	if err := db.AutoMigrate(
		&UserCompetitionAward{},
		&CompetitionAwardVerificationLog{},
		&CompetitionAwardEvidenceFile{},
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
		&CompetitionAwardEvidenceFile{},
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
	privateFile := CompetitionAwardEvidenceFile{
		UploaderID: 1, Hash: "private-hash", Path: "1/pr/private.png",
		MimeType: "image/png", Size: 12, Status: "active",
	}
	if err := db.Create(&privateFile).Error; err != nil {
		t.Fatal(err)
	}
	award := UserCompetitionAward{
		UserID: 1, CompetitionTitle: "历史赛事", CompetitionYear: 2025,
		AwardName: "二等奖", CompetitionStage: "provincial", Role: "member",
		SkillTags: []byte("[]"), EvidenceFileIDs: []byte("[1]"),
		VerificationStatus: "self_reported", Visibility: "private",
	}
	if err := db.Create(&award).Error; err != nil {
		t.Fatal(err)
	}
	mapping := CompetitionAwardEvidence{AwardID: award.ID, FileID: privateFile.ID}
	if err := db.Create(&mapping).Error; err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := db.AutoMigrate(&CompetitionAwardEvidenceFile{}, &CompetitionAwardEvidence{}); err != nil {
			t.Fatal(err)
		}
	}
	var persistedFile CompetitionAwardEvidenceFile
	if err := db.First(&persistedFile, privateFile.ID).Error; err != nil {
		t.Fatal(err)
	}
	var mappingCount int64
	if err := db.Model(&CompetitionAwardEvidence{}).Where("award_id = ? AND file_id = ?", award.ID, privateFile.ID).Count(&mappingCount).Error; err != nil || mappingCount != 1 {
		t.Fatalf("private evidence mapping count=%d err=%v", mappingCount, err)
	}
}
