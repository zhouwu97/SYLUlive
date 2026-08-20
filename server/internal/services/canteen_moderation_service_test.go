package services

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"shenliyuan/internal/models"
)

func TestCanteenPenaltyForReason(t *testing.T) {
	if got := CanteenPenaltyForReason("fabricated"); got != CanteenPenaltyNormal {
		t.Fatalf("fabricated penalty=%d want %d", got, CanteenPenaltyNormal)
	}
	if got := CanteenPenaltyForReason("malicious_repeat"); got != CanteenPenaltyMalice {
		t.Fatalf("malicious penalty=%d want %d", got, CanteenPenaltyMalice)
	}
	if got := CanteenPenaltyForReason("blurry"); got != 0 {
		t.Fatalf("quality rejection penalty=%d want 0", got)
	}
}

func TestApplyCanteenSanctionIsIdempotent(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.CanteenSanction{}); err != nil {
		t.Fatalf("migrate database: %v", err)
	}
	user := models.User{ID: 1001, StudentID: "sanction-test", PasswordHash: "test", Nickname: "被举报用户", CreditScore: 80}
	if err := db.Create(&user).Error; err != nil {
		t.Fatalf("create user: %v", err)
	}

	applied, err := ApplyCanteenSanction(db, 9, "canteen_review", 11, user.ID, 99, "fabricated")
	if err != nil || !applied {
		t.Fatalf("first sanction applied=%v err=%v", applied, err)
	}
	applied, err = ApplyCanteenSanction(db, 9, "canteen_review", 11, user.ID, 99, "fabricated")
	if err != nil || applied {
		t.Fatalf("duplicate sanction applied=%v err=%v", applied, err)
	}
	var updated models.User
	if err := db.First(&updated, user.ID).Error; err != nil {
		t.Fatalf("load user: %v", err)
	}
	if updated.CreditScore != 75 {
		t.Fatalf("credit score=%d want 75", updated.CreditScore)
	}
	var count int64
	if err := db.Model(&models.CanteenSanction{}).Count(&count).Error; err != nil {
		t.Fatalf("count sanctions: %v", err)
	}
	if count != 1 {
		t.Fatalf("sanction count=%d want 1", count)
	}
}
