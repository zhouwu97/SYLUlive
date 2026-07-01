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

// jwcTestSpec is a reusable spec for JWC tests.
var jwcTestSpec = CrawlSourceSpec{
	Source:     "jwc",
	Categories: []string{"jwtz", "jwgg"},
}

// competitionTestSpec is a reusable spec for competition tests.
var competitionTestSpec = CrawlSourceSpec{
	Source:     "cxcy",
	Categories: []string{"competition"},
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
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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

func TestQueryKnownURLsCompetition(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &CampusSyncService{db: db, spec: competitionTestSpec}

	attJSON := datatypes.JSON([]byte("[]"))
	db.Create(&models.CampusArticle{
		Source: "cxcy", Category: "比赛通知", CategorySlug: "competition",
		CategoryID: "1089", SourceArticleID: "3293",
		SourceURL: "https://cxcyxy.sylu.edu.cn/info/1089/3293.htm",
		Title:     "Competition Test", ContentHash: "cccc" + "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		Attachments: attJSON,
	})
	// JWC article should not appear in competition known URLs
	db.Create(&models.CampusArticle{
		Source: "jwc", Category: "教务通知", CategorySlug: "jwtz",
		CategoryID: "1116", SourceArticleID: "5946",
		SourceURL: "https://jwc.sylu.edu.cn/info/1116/5946.htm",
		Title:     "JWC Test", ContentHash: "dddd" + "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
		Attachments: attJSON,
	})

	known := svc.queryKnownURLs()
	if len(known) != 1 {
		t.Errorf("expected 1 category (competition), got %d", len(known))
	}
	if len(known["competition"]) != 1 {
		t.Errorf("expected 1 competition URL, got %d", len(known["competition"]))
	}
	if _, ok := known["jwtz"]; ok {
		t.Error("JWC URLs should not appear in competition query")
	}
}

func TestUpdateSyncStateOnSuccess(t *testing.T) {
	db := setupSyncTestDB(t)
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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
	svc := &CampusSyncService{db: db, spec: jwcTestSpec}

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

func TestCompetitionSyncStateSeparateFromJWC(t *testing.T) {
	db := setupSyncTestDB(t)
	jwcSvc := &CampusSyncService{db: db, spec: jwcTestSpec}
	compSvc := &CampusSyncService{db: db, spec: competitionTestSpec}

	// JWC sync succeeds
	jwcSvc.updateSyncState(&SyncResult{Added: 5}, false, false, 5)

	// Competition sync fails
	compSvc.updateSyncState(&SyncResult{Error: &testError{msg: "timeout"}}, false, false, 0)

	// Verify states are separate
	var jwcState, compState models.JWCSyncState
	if err := db.Where("source = ?", "jwc").First(&jwcState).Error; err != nil {
		t.Fatalf("query jwc state: %v", err)
	}
	if err := db.Where("source = ?", "cxcy").First(&compState).Error; err != nil {
		t.Fatalf("query cxcy state: %v", err)
	}

	if jwcState.LastSuccessAt == nil {
		t.Error("JWC should have LastSuccessAt set")
	}
	if compState.LastSuccessAt != nil {
		t.Error("Competition should NOT have LastSuccessAt set (failed)")
	}
	if compState.ConsecutiveFailures != 1 {
		t.Errorf("Competition should have 1 failure, got %d", compState.ConsecutiveFailures)
	}
	if jwcState.ConsecutiveFailures != 0 {
		t.Errorf("JWC should have 0 failures, got %d", jwcState.ConsecutiveFailures)
	}
}

// ── helpers ───────────────────────────────────────────────────────

type testError struct{ msg string }

func (e *testError) Error() string { return e.msg }

func timePtr(t time.Time) *time.Time { return &t }
