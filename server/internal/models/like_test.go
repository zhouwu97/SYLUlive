package models_test

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestLike_UniqueIndex(t *testing.T) {
	// Setup in-memory sqlite db for testing
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("failed to connect database: %v", err)
	}

	// Migrate the schema
	err = db.AutoMigrate(&models.Like{})
	if err != nil {
		t.Fatalf("failed to migrate database: %v", err)
	}

	like1 := models.Like{
		UserID:     1,
		TargetType: "post",
		TargetID:   10,
	}

	// First insert should succeed
	result := db.Create(&like1)
	if result.Error != nil {
		t.Errorf("expected no error on first insert, got %v", result.Error)
	}

	like2 := models.Like{
		UserID:     1,
		TargetType: "post",
		TargetID:   10,
	}

	// Second insert with same unique keys should fail
	result2 := db.Create(&like2)
	if result2.Error == nil {
		t.Errorf("expected error on duplicate insert due to unique index, got none")
	}

	// Different UserID should succeed
	like3 := models.Like{
		UserID:     2,
		TargetType: "post",
		TargetID:   10,
	}
	result3 := db.Create(&like3)
	if result3.Error != nil {
		t.Errorf("expected no error on different user id, got %v", result3.Error)
	}
}
