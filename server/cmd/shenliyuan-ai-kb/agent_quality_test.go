package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func writeAgentQualityFixture(t *testing.T, evidenceType, version string, blocked bool) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "quality.json")
	report := map[string]any{
		"schema_version":     agentQualityGateSchemaVersion,
		"evidence_type":      evidenceType,
		"knowledge_version":  version,
		"blocked":            blocked,
		"publish_decision":   map[bool]string{true: "blocked", false: "eligible_for_review"}[blocked],
		"rollout_decision":   map[bool]string{true: "blocked", false: "eligible_for_review"}[blocked],
		"gates":              map[string]string{"holdout_citation_validity": map[bool]string{true: "fail", false: "pass"}[blocked]},
		"requests_performed": 0,
		"writes_performed":   false,
	}
	encoded, err := json.Marshal(report)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(path, encoded, 0o600))
	return path
}

func TestInspectAgentQualityReportRequiresRuntimeEvidenceForRelease(t *testing.T) {
	fixture := writeAgentQualityFixture(t, "fixture", "v0.8", false)
	inspection, err := inspectAgentQualityReport(fixture, "v0.8", true)
	require.Error(t, err)
	require.Equal(t, "failed", inspection.Status)

	staging := writeAgentQualityFixture(t, "staging", "v0.8", false)
	inspection, err = inspectAgentQualityReport(staging, "v0.8", true)
	require.NoError(t, err)
	require.Equal(t, "passed", inspection.Status)
	require.NotEmpty(t, inspection.ReportSHA256)
}

func TestInspectAgentQualityReportBlocksFailedQuality(t *testing.T) {
	reportPath := writeAgentQualityFixture(t, "staging", "v0.8", true)
	inspection, err := inspectAgentQualityReport(reportPath, "v0.8", true)
	require.Error(t, err)
	require.Equal(t, "blocked", inspection.Status)
}

func TestInspectAgentQualityReportRejectsKnowledgeVersionDrift(t *testing.T) {
	reportPath := writeAgentQualityFixture(t, "staging", "v0.7", false)
	inspection, err := inspectAgentQualityReport(reportPath, "v0.8", true)
	require.Error(t, err)
	require.Equal(t, "failed", inspection.Status)
}
