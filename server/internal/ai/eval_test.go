package ai

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestFixedEvaluationFixturesPass(t *testing.T) {
	report, err := RunFixedEvaluation(filepath.Join("..", "..", "testdata", "ai_eval"))
	require.NoError(t, err)
	require.Zero(t, report.Failed)
	require.Equal(t, report.Total, report.Passed)
}
