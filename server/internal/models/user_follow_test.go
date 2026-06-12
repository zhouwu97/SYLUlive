package models_test

import (
	"testing"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestUserFollow_UniqueIndexAndFields(t *testing.T) {
	// Setup in-memory sqlite db for testing
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("failed to connect database: %v", err)
	}

	// Migrate the schema
	err = db.AutoMigrate(&models.UserFollow{})
	if err != nil {
		t.Fatalf("failed to migrate database: %v", err)
	}

	follow1 := models.UserFollow{
		FollowerID:  1,
		FollowingID: 2,
	}

	// First insert should succeed
	result := db.Create(&follow1)
	if result.Error != nil {
		t.Errorf("expected no error on first insert, got %v", result.Error)
	}

	follow2 := models.UserFollow{
		FollowerID:  1,
		FollowingID: 2,
	}

	// Second insert with same unique keys should fail
	result2 := db.Create(&follow2)
	if result2.Error == nil {
		t.Errorf("expected error on duplicate insert due to unique index, got none")
	}

	// Different Follower/Following should succeed
	follow3 := models.UserFollow{
		FollowerID:  2,
		FollowingID: 1,
	}
	result3 := db.Create(&follow3)
	if result3.Error != nil {
		t.Errorf("expected no error on different ids, got %v", result3.Error)
	}
}
