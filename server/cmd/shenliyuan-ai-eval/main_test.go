package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"

	"shenliyuan/internal/ai"

	"github.com/stretchr/testify/require"
)

func TestRunDefaultsToOfflineFixtureMode(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	dataDirectory := filepath.Join("..", "..", "testdata", "ai_eval")
	code := run([]string{"--data", dataDirectory}, func(string) string {
		t.Fatal("fixture 模式不应读取环境变量")
		return ""
	}, &stdout, &stderr)
	require.Zero(t, code, stderr.String())

	var report ai.EvaluationReport
	require.NoError(t, json.Unmarshal(stdout.Bytes(), &report))
	require.Equal(t, "fixture", report.Mode)
	require.Equal(t, 45, report.Total)
	require.Zero(t, report.Failed)
}

func TestRunLiveModeReportsMissingDependencies(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	dataDirectory := filepath.Join("..", "..", "testdata", "ai_eval")
	code := run([]string{"--mode", "live", "--data", dataDirectory}, func(string) string { return "" }, &stdout, &stderr)
	require.Equal(t, 2, code)
	require.Empty(t, stdout.String())
	for _, name := range []string{"DATABASE_DSN", "RAG_SERVICE_URL", "RAG_SERVICE_TOKEN", "AI_API_KEY"} {
		require.Contains(t, stderr.String(), name)
	}
}
