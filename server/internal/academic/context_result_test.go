package academic

import (
	"encoding/json"
	"testing"
	"time"
)

func TestContextResultHasCompleteSerializableEnvelope(t *testing.T) {
	result, err := NewContextResult(map[string]any{"failed_course_count": 2}, DataStatusAvailable, DataSourceServerSnapshot)
	if err != nil {
		t.Fatalf("NewContextResult() error = %v", err)
	}
	now := time.Date(2026, 7, 25, 9, 20, 0, 0, time.FixedZone("CST", 8*60*60))
	result.FetchedAt = &now
	result.Evidence = []Evidence{{
		Source: DataSourceServerSnapshot, Dataset: DatasetGrades, FetchedAt: &now,
	}}
	if err := result.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}

	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("Marshal() error = %v", err)
	}
	var envelope map[string]any
	if err := json.Unmarshal(encoded, &envelope); err != nil {
		t.Fatalf("Unmarshal() error = %v", err)
	}
	for _, key := range []string{"data", "source", "is_stale", "is_partial", "warnings", "evidence"} {
		if _, ok := envelope[key]; !ok {
			t.Errorf("serialized result misses %q", key)
		}
	}
}

func TestResolveContextRequestRejectsInvalidInput(t *testing.T) {
	tests := []ResolveContextRequest{
		{Freshness: FreshnessPreferRecent},
		{Datasets: []DatasetType{"unknown"}, Freshness: FreshnessPreferRecent},
		{Datasets: []DatasetType{DatasetGrades, DatasetGrades}, Freshness: FreshnessPreferRecent},
		{Datasets: []DatasetType{DatasetGrades}, Freshness: "latest"},
		{Datasets: []DatasetType{DatasetSchedule}, Freshness: FreshnessPreferRecent},
		{Datasets: []DatasetType{DatasetSchedule}, Freshness: FreshnessPreferRecent, ScheduleWeekContaining: "2026/09/14"},
	}
	for _, request := range tests {
		if err := request.Validate(); err == nil {
			t.Errorf("Validate() accepted %#v", request)
		}
	}
}

func TestResolveContextRequestAcceptsScheduleWeekContaining(t *testing.T) {
	request := ResolveContextRequest{
		Datasets: []DatasetType{DatasetSchedule}, Freshness: FreshnessPreferRecent,
		ScheduleWeekContaining: "2026-09-14",
	}
	if err := request.Validate(); err != nil {
		t.Fatalf("Validate() rejected valid schedule target: %v", err)
	}
}
