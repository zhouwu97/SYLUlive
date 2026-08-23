package services

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"shenliyuan/internal/academic"
)

func TestLookupLatestGradesMergesAllTermSnapshots(t *testing.T) {
	now := time.Date(2026, 8, 23, 10, 0, 0, 0, time.UTC)
	_, snapshots, _ := newEduFetchTestFixture(t, &fakeEduContextFetcher{}, now)

	for _, item := range []struct {
		scope string
		when  time.Time
		body  string
	}{
		{scope: "2025-2026:3", when: now.Add(-2 * time.Hour), body: `{"grades":[{"course_name":"高等数学","credits":4,"gpa":2.5,"fraction":75}]}`},
		{scope: "2025-2026:12", when: now.Add(-time.Hour), body: `{"grades":[{"course_name":"信号与系统","credits":3,"gpa":0,"fraction":55.8}]}`},
	} {
		if err := snapshots.StoreRemote(context.Background(), AcademicSnapshotInput{
			UserID: 1, Dataset: academic.DatasetGrades, ScopeKey: item.scope, SchemaVersion: 1,
			Source: academic.DataSourceRemoteEduFetch, Payload: json.RawMessage(item.body),
			FetchedAt: item.when, ExpiresAt: now.Add(time.Hour), CredentialGeneration: 1,
		}); err != nil {
			t.Fatal(err)
		}
	}

	lookup, err := snapshots.LookupLatest(context.Background(), 1, academic.DatasetGrades, 1)
	if err != nil {
		t.Fatal(err)
	}
	if !lookup.Found || lookup.Result.Status != academic.DataStatusAvailable {
		t.Fatalf("expected merged available grades, got found=%v status=%s", lookup.Found, lookup.Result.Status)
	}
	var payload struct {
		Grades       []map[string]interface{} `json:"grades"`
		CoveredTerms []map[string]interface{} `json:"covered_terms"`
	}
	if err := json.Unmarshal(lookup.Result.Data, &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Grades) != 2 || len(payload.CoveredTerms) != 2 {
		t.Fatalf("expected two term records, got grades=%d terms=%d", len(payload.Grades), len(payload.CoveredTerms))
	}
}
