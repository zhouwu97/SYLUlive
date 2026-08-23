package main

import (
	"bytes"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRunDeterministicRegressionSuite(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-baseline", filepath.Join("..", "..", "internal", "ai", "eval", "baseline.json")}, &stdout, &stderr)
	require.Zero(t, code, stderr.String())
	require.Contains(t, stdout.String(), "Agent Regression Suite")
	require.Contains(t, stdout.String(), "Cases                 68")
	require.Contains(t, stdout.String(), "Success Rate          100.0%")
}

func TestRunRegressionSuiteJSON(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"-json", "-baseline", filepath.Join("..", "..", "internal", "ai", "eval", "baseline.json")}, &stdout, &stderr)
	require.Zero(t, code, stderr.String())
	require.Contains(t, stdout.String(), `"summary"`)
	require.Contains(t, stdout.String(), `"violations": []`)
}
