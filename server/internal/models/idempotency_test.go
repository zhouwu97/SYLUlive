package models

import (
	"testing"

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
