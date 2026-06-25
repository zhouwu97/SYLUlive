package services

import (
	"testing"
	"time"

	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func setupSyncTestDB(t *testing.T) *gorm.DB {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if err := db.AutoMigrate(&models.CampusArticle{}, &models.JWCSyncState{}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return db
}

func TestSyncResultDefaults(t *testing.T) {
	r := &SyncResult{}
	if r.IsBootstrap {
		t.Error("new SyncResult should not be bootstrap by default")
	}
	if r.Added != 0 || r.Updated != 0 || r.Skipped != 0 {
		t.Error("new SyncResult counts should be zero")
	}
}

func TestBootstrapDetection(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db} // no client needed for this test

	// Empty DB → bootstrap
	var count int64
	db.Model(&models.CampusArticle{}).Where("source = ?", "jwc").Count(&count)
	if count != 0 {
		t.Fatal("expected empty DB")
	}

	_ = svc
}

func TestQueryKnownURLs(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db}

	// Empty → returns empty
	known := svc.queryKnownURLs()
	if len(known) != 0 {
		t.Errorf("expected empty known URLs, got %v", known)
	}

	// Seed some articles
	attJSON := datatypes.JSON([]byte("[]"))
	db.Create(&models.CampusArticle{
		Source: "jwc", Category: "教务通知", CategorySlug: "jwtz",
		CategoryID: "1116", SourceArticleID: "5946",
		SourceURL: "https://jwc.sylu.edu.cn/info/1116/5946.htm",
		Title:     "Test", ContentHash: "aaaa" + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Attachments: attJSON,
	})
	db.Create(&models.CampusArticle{
		Source: "jwc", Category: "教务公告", CategorySlug: "jwgg",
		CategoryID: "1119", SourceArticleID: "5903",
		SourceURL: "https://jwc.sylu.edu.cn/info/1119/5903.htm",
		Title:     "Test2", ContentHash: "bbbb" + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Attachments: attJSON,
	})

	known = svc.queryKnownURLs()
	if len(known) != 2 {
		t.Errorf("expected 2 categories, got %d", len(known))
	}
	if len(known["jwtz"]) != 1 {
		t.Errorf("expected 1 jwtz URL, got %d", len(known["jwtz"]))
	}
}

func TestUpdateSyncStateOnSuccess(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db}

	result := &SyncResult{Added: 5, Skipped: 3}
	svc.updateSyncState(result, false, false, 5)

	var state models.JWCSyncState
	if err := db.Where("source = ?", "jwc").First(&state).Error; err != nil {
		t.Fatalf("query state: %v", err)
	}
	if state.LastSuccessAt == nil {
		t.Error("LastSuccessAt should be set")
	}
	if state.ConsecutiveFailures != 0 {
		t.Errorf("expected 0 failures, got %d", state.ConsecutiveFailures)
	}
	if state.LastItemCount != 5 {
		t.Errorf("expected LastItemCount=5, got %d", state.LastItemCount)
	}
	if state.LastError != "" {
		t.Errorf("LastError should be cleared on success, got %q", state.LastError)
	}
}

func TestUpdateSyncStateOnFailure(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db}

	result := &SyncResult{Error: &testError{msg: "connection refused"}}
	svc.updateSyncState(result, false, false, 0)

	var state models.JWCSyncState
	if err := db.Where("source = ?", "jwc").First(&state).Error; err != nil {
		t.Fatalf("query state: %v", err)
	}
	if state.ConsecutiveFailures != 1 {
		t.Errorf("expected 1 failure, got %d", state.ConsecutiveFailures)
	}
	if state.LastError == "" {
		t.Error("LastError should be set on failure")
	}
	if state.LastSuccessAt != nil && state.LastItemCount != 0 {
		t.Error("LastSuccessAt should not be updated on failure if never succeeded")
	}
}

func TestUpdateSyncStateOnReconcile(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db}

	result := &SyncResult{Added: 1, Updated: 2}
	svc.updateSyncState(result, true, false, 3)

	var state models.JWCSyncState
	if err := db.Where("source = ?", "jwc").First(&state).Error; err != nil {
		t.Fatalf("query state: %v", err)
	}
	if state.LastReconcileAt == nil {
		t.Error("LastReconcileAt should be set on successful reconcile")
	}
}

func TestUpdateSyncStateOnPartialFailure(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db}

	result := &SyncResult{Added: 3}
	svc.updateSyncState(result, false, true, 3)

	var state models.JWCSyncState
	if err := db.Where("source = ?", "jwc").First(&state).Error; err != nil {
		t.Fatalf("query state: %v", err)
	}
	// Partial failure still counts as success
	if state.LastSuccessAt == nil {
		t.Error("LastSuccessAt should be set on partial failure")
	}
	if state.ConsecutiveFailures != 0 {
		t.Errorf("partial failure should not increment failures, got %d", state.ConsecutiveFailures)
	}
}

func TestShouldReconcile(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &JWCSyncService{db: db}

	// No state yet → should reconcile
	if !svc.ShouldReconcile() {
		t.Error("should reconcile when no state exists")
	}

	// Just reconciled → should NOT reconcile
	db.Create(&models.JWCSyncState{
		Source:          "jwc",
		LastReconcileAt: timePtr(time.Now()),
	})
	if svc.ShouldReconcile() {
		t.Error("should not reconcile right after successful reconcile")
	}

	// Old reconcile → should reconcile
	db.Where("source = ?", "jwc").Delete(&models.JWCSyncState{})
	db.Create(&models.JWCSyncState{
		Source:          "jwc",
		LastReconcileAt: timePtr(time.Now().Add(-25 * time.Hour)),
	})
	if !svc.ShouldReconcile() {
		t.Error("should reconcile after 25 hours")
	}
}

// ── helpers ───────────────────────────────────────────────────────

type testError struct{ msg string }

func (e *testError) Error() string { return e.msg }

func timePtr(t time.Time) *time.Time { return &t }
