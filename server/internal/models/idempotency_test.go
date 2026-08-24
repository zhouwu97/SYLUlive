package models

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func TestEnsureIdempotencySchemaIsRepeatable(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := EnsureIdempotencySchema(db); err != nil {
		t.Fatalf("first migration: %v", err)
	}
	if err := EnsureIdempotencySchema(db); err != nil {
		t.Fatalf("second migration: %v", err)
	}
	if err := db.Create(&IdempotencyRecord{
		Scope: "user:1", Key: "test-key", Method: "POST", Path: "/api/test",
		RequestHash: "hash", State: IdempotencyStateCompleted,
	}).Error; err != nil {
		t.Fatalf("insert migrated record: %v", err)
	}
}

func TestEnsureIdempotencySchemaRejectsNilDatabase(t *testing.T) {
	if err := EnsureIdempotencySchema(nil); err == nil {
		t.Fatal("nil database migration should fail")
	}
}

func TestCleanupExpiredIdempotencyRecordsKeepsLiveAndProcessingRows(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := EnsureIdempotencySchema(db); err != nil {
		t.Fatalf("migration: %v", err)
	}
	now := time.Date(2026, 8, 24, 12, 0, 0, 0, time.UTC)
	rows := []IdempotencyRecord{
		{Scope: "user:1", Key: "expired-completed", Method: "POST", Path: "/api/test", RequestHash: "a", State: IdempotencyStateCompleted, ExpiresAt: now.Add(-time.Minute)},
		{Scope: "user:1", Key: "expired-processing", Method: "POST", Path: "/api/test", RequestHash: "b", State: IdempotencyStateProcessing, ExpiresAt: now.Add(-time.Minute)},
		{Scope: "user:1", Key: "live", Method: "POST", Path: "/api/test", RequestHash: "c", State: IdempotencyStateCompleted, ExpiresAt: now.Add(time.Hour)},
	}
	if err := db.Create(&rows).Error; err != nil {
		t.Fatalf("seed records: %v", err)
	}

	deleted, err := CleanupExpiredIdempotencyRecords(db, now, 100)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted=%d, want 1; processing row must be retained for safe replay", deleted)
	}
	var processing IdempotencyRecord
	if err := db.Where("id = ?", rows[1].ID).First(&processing).Error; err != nil {
		t.Fatalf("processing row missing: %v", err)
	}
	if processing.State != IdempotencyStateFailed {
		t.Fatalf("processing state=%q, want failed", processing.State)
	}
	var liveCount int64
	if err := db.Model(&IdempotencyRecord{}).Where("id = ?", rows[2].ID).Count(&liveCount).Error; err != nil {
		t.Fatalf("count live record: %v", err)
	}
	if liveCount != 1 {
		t.Fatal("live idempotency record was removed")
	}
	deleted, err = CleanupExpiredIdempotencyRecords(db, now, 100)
	if err != nil {
		t.Fatalf("second cleanup: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("second cleanup deleted=%d, want 1 failed record", deleted)
	}
}
