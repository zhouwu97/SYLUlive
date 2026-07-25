package ai

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/academic"
)

type fixedPersonalSnapshotReader struct {
	lookup academic.SnapshotLookup
	err    error
}

func (reader fixedPersonalSnapshotReader) LookupErke(context.Context, uint) (academic.SnapshotLookup, error) {
	return reader.lookup, reader.err
}

func campusToolByName(t *testing.T, tools []PureReadTool, name string) PureReadTool {
	t.Helper()
	for _, tool := range tools {
		if tool.Name() == name {
			return tool
		}
	}
	t.Fatalf("tool %q not found", name)
	return nil
}

func TestCampusMCPErkeUsesUploadedSnapshotWithoutAcademicCredential(t *testing.T) {
	now := time.Date(2026, 7, 25, 9, 0, 0, 0, time.UTC)
	reader := fixedPersonalSnapshotReader{lookup: academic.SnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data:      json.RawMessage(`{"earned_total":42.5,"required_total":60,"unmet_categories":[{"name":"创新创业","gap":4}]}`),
			Status:    academic.DataStatusAvailable,
			Source:    academic.DataSourceUserUploadedSnapshot,
			FetchedAt: &now,
			Warnings:  make([]string, 0),
			Evidence: []academic.Evidence{{
				Source: academic.DataSourceUserUploadedSnapshot, Dataset: academic.DatasetErke, FetchedAt: &now,
			}},
		},
	}}
	tools := NewCampusMCPTools(nil, nil, reader)
	result, err := campusToolByName(t, tools, "erke.get_overview").Execute(context.Background(), 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	envelope, ok := result.(CampusToolResult)
	require.True(t, ok)
	require.Equal(t, academic.DataSourceUserUploadedSnapshot, envelope.Source)
	require.Equal(t, academic.DataStatusAvailable, envelope.Status)
	require.Equal(t, 42.5, envelope.Data.(map[string]interface{})["earned_total"])

	resolved, err := campusToolByName(t, tools, "academic.resolve_context").Execute(context.Background(), 7, json.RawMessage(`{"datasets":["erke"],"freshness":"prefer_recent","reason":"erke_overview"}`))
	require.NoError(t, err)
	resolvedEnvelope := resolved.(CampusToolResult)
	require.Equal(t, academic.DataSourceUserUploadedSnapshot, resolvedEnvelope.Data.(map[string]academic.ContextResult)["erke"].Source)
}

func TestCampusMCPErkeOverviewReadsStructuredUploadedSnapshot(t *testing.T) {
	reader := fixedPersonalSnapshotReader{lookup: academic.SnapshotLookup{
		Found: true,
		Result: academic.ContextResult{
			Data: json.RawMessage(`{
				"graduation":{"earned_total":42.5,"required_total":60,"graduation_gap":17.5,"unmet_categories":[{"name":"创新创业","gap":4}]},
				"yearly":{"year":"2025-2026","yearly_gap":4},
				"recent_activities":[{"category":"创新创业","score":1.5,"date":"2026-07-25"}]
			}`),
			Status:   academic.DataStatusAvailable,
			Source:   academic.DataSourceUserUploadedSnapshot,
			Warnings: make([]string, 0),
			Evidence: make([]academic.Evidence, 0),
		},
	}}
	tools := NewCampusMCPTools(nil, nil, reader)
	result, err := campusToolByName(t, tools, "erke.get_overview").Execute(context.Background(), 7, json.RawMessage(`{}`))
	require.NoError(t, err)
	overview := result.(CampusToolResult).Data.(map[string]interface{})
	require.Equal(t, 42.5, overview["earned_total"])
	require.Equal(t, 60.0, overview["required_total"])
	require.Equal(t, "2025-2026", overview["year"])
	require.Equal(t, 1, overview["activity_count"])
}
