package services

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/clients"
	"shenliyuan/internal/models"
)

type fakeEduContextFetcher struct {
	mu      sync.Mutex
	calls   int
	bundle  clients.EduContextBundle
	err     error
	started chan struct{}
	release chan struct{}
}

func (fetcher *fakeEduContextFetcher) FetchContextBundle(_ context.Context, _ uint, datasets []clients.EduContextDataset) (clients.EduContextBundle, error) {
	fetcher.mu.Lock()
	fetcher.calls++
	started := fetcher.started
	release := fetcher.release
	bundle := fetcher.bundle
	err := fetcher.err
	fetcher.mu.Unlock()
	if started != nil {
		select {
		case started <- struct{}{}:
		default:
		}
	}
	if release != nil {
		<-release
	}
	if err != nil {
		return clients.EduContextBundle{}, err
	}
	if bundle.Results == nil {
		bundle.Results = map[string]clients.EduContextItem{
			datasets[0].Key(): {Status: "success", Data: json.RawMessage(`{"success":true,"grades":[]}`)},
		}
	}
	return bundle, nil
}

func (fetcher *fakeEduContextFetcher) callCount() int {
	fetcher.mu.Lock()
	defer fetcher.mu.Unlock()
	return fetcher.calls
}

func newEduFetchTestFixture(t *testing.T, fetcher *fakeEduContextFetcher, now time.Time) (*gorm.DB, *AcademicSnapshotService, *EduFetchOrchestrator) {
	t.Helper()
	db, err := gorm.Open(sqlite.Open("file:"+t.Name()+"?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&models.User{}, &models.AcademicSnapshot{}); err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.User{
		PasswordHash: "test", EduAuthorized: true, EduSessionState: "active", EduAuthorizationGeneration: 1,
	}).Error; err != nil {
		t.Fatal(err)
	}
	snapshots := NewAcademicSnapshotService(db, func() time.Time { return now })
	orchestrator := NewEduFetchOrchestrator(db, fetcher, snapshots, EduFetchOrchestratorOptions{
		Now: func() time.Time { return now }, Timeout: time.Second, MaxInflight: 2,
	})
	return db, snapshots, orchestrator
}

func gradesRequest(forceRefresh bool) EduFetchRequest {
	return EduFetchRequest{
		Dataset: academic.DatasetGrades, Year: "2025-2026", Semester: 3, ForceRefresh: forceRefresh,
	}
}

func TestEduFetchUsesFreshSnapshotBeforeRemoteFetch(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	fetcher := &fakeEduContextFetcher{}
	db, snapshots, orchestrator := newEduFetchTestFixture(t, fetcher, now)
	if err := snapshots.StoreRemote(context.Background(), AcademicSnapshotInput{
		UserID: 1, Dataset: academic.DatasetGrades, ScopeKey: "2025-2026:3", SchemaVersion: 1,
		Source: academic.DataSourceRemoteEduFetch, Payload: json.RawMessage(`{"success":true,"grades":["cached"]}`),
		FetchedAt: now.Add(-time.Hour), ExpiresAt: now.Add(time.Hour), CredentialGeneration: 1,
	}); err != nil {
		t.Fatal(err)
	}
	result, err := orchestrator.Fetch(context.Background(), 1, gradesRequest(false))
	if err != nil {
		t.Fatal(err)
	}
	if result.Source != academic.DataSourceServerSnapshot || fetcher.callCount() != 0 {
		t.Fatalf("expected fresh snapshot without remote call, source=%s calls=%d", result.Source, fetcher.callCount())
	}
	var payload map[string]any
	if err := json.Unmarshal(result.Data, &payload); err != nil || payload["success"] != true {
		t.Fatalf("unexpected cached payload: %s", result.Data)
	}
	_ = db
}

func TestEduFetchDeduplicatesConcurrentRefreshes(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	fetcher := &fakeEduContextFetcher{started: make(chan struct{}, 1), release: make(chan struct{})}
	_, _, orchestrator := newEduFetchTestFixture(t, fetcher, now)
	results := make(chan academic.ContextResult, 2)
	errorsCh := make(chan error, 2)
	for range 2 {
		go func() {
			result, err := orchestrator.Fetch(context.Background(), 1, gradesRequest(true))
			results <- result
			errorsCh <- err
		}()
	}
	select {
	case <-fetcher.started:
	case <-time.After(time.Second):
		t.Fatal("remote fetch did not start")
	}
	close(fetcher.release)
	for range 2 {
		if err := <-errorsCh; err != nil {
			t.Fatal(err)
		}
		if result := <-results; result.Source != academic.DataSourceRemoteEduFetch {
			t.Fatalf("unexpected result source: %s", result.Source)
		}
	}
	if fetcher.callCount() != 1 {
		t.Fatalf("expected one remote call, got %d", fetcher.callCount())
	}
}

func TestEduFetchRejectsOldCredentialGenerationWrite(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	fetcher := &fakeEduContextFetcher{started: make(chan struct{}, 1), release: make(chan struct{})}
	db, snapshots, orchestrator := newEduFetchTestFixture(t, fetcher, now)
	resultCh := make(chan academic.ContextResult, 1)
	go func() {
		result, _ := orchestrator.Fetch(context.Background(), 1, gradesRequest(true))
		resultCh <- result
	}()
	select {
	case <-fetcher.started:
	case <-time.After(time.Second):
		t.Fatal("remote fetch did not start")
	}
	if err := db.Model(&models.User{}).Where("id = ?", 1).Update("edu_authorization_generation", 2).Error; err != nil {
		t.Fatal(err)
	}
	close(fetcher.release)
	result := <-resultCh
	if result.Status != academic.DataStatusPermissionRequired {
		t.Fatalf("expected permission_required, got %s", result.Status)
	}
	lookup, err := snapshots.Lookup(context.Background(), 1, academic.DatasetGrades, "2025-2026:3", 2)
	if err != nil {
		t.Fatal(err)
	}
	if lookup.Found {
		t.Fatal("old authorization generation must not write a snapshot")
	}
}

func TestEduFetchFallsBackToStaleSnapshotWhenRemoteFails(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	fetcher := &fakeEduContextFetcher{err: errors.New("upstream unavailable")}
	_, snapshots, orchestrator := newEduFetchTestFixture(t, fetcher, now)
	if err := snapshots.StoreRemote(context.Background(), AcademicSnapshotInput{
		UserID: 1, Dataset: academic.DatasetGrades, ScopeKey: "2025-2026:3", SchemaVersion: 1,
		Source: academic.DataSourceRemoteEduFetch, Payload: json.RawMessage(`{"success":true,"grades":["old"]}`),
		FetchedAt: now.Add(-2 * time.Hour), ExpiresAt: now.Add(-time.Hour), CredentialGeneration: 1,
	}); err != nil {
		t.Fatal(err)
	}
	result, err := orchestrator.Fetch(context.Background(), 1, gradesRequest(true))
	if err != nil {
		t.Fatal(err)
	}
	if result.Source != academic.DataSourceServerSnapshot || result.Status != academic.DataStatusStale || !result.IsStale {
		t.Fatalf("expected stale fallback, got source=%s status=%s stale=%t", result.Source, result.Status, result.IsStale)
	}
}

func TestEduFetchDoesNotHideAuthorizationFailureBehindStaleSnapshot(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	fetcher := &fakeEduContextFetcher{bundle: clients.EduContextBundle{Results: map[string]clients.EduContextItem{
		"grades:2025-2026:3": {Status: "failed", ErrorCode: "EDU_SESSION_EXPIRED", Message: "会话已过期"},
	}}}
	_, snapshots, orchestrator := newEduFetchTestFixture(t, fetcher, now)
	if err := snapshots.StoreRemote(context.Background(), AcademicSnapshotInput{
		UserID: 1, Dataset: academic.DatasetGrades, ScopeKey: "2025-2026:3", SchemaVersion: 1,
		Source: academic.DataSourceRemoteEduFetch, Payload: json.RawMessage(`{"success":true,"grades":["old"]}`),
		FetchedAt: now.Add(-2 * time.Hour), ExpiresAt: now.Add(-time.Hour), CredentialGeneration: 1,
	}); err != nil {
		t.Fatal(err)
	}
	result, err := orchestrator.Fetch(context.Background(), 1, gradesRequest(true))
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != academic.DataStatusPermissionRequired || result.Source != academic.DataSourceNone {
		t.Fatalf("authorization failure must not use stale snapshot: source=%s status=%s", result.Source, result.Status)
	}
}
