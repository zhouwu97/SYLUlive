package ai

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestV06PolicyRuleCasesAreComplete(t *testing.T) {
	path := filepath.Join(
		"..", "..", "..", "knowledge-base", "sylu-academic-policy", "v0.6",
		"SYLUlive_政策规则测试用例_v0.6.json",
	)
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	var suite struct {
		Version string `json:"version"`
		Cases   []struct {
			CaseID   string   `json:"case_id"`
			Question string   `json:"question"`
			Expected string   `json:"expected"`
			Source   string   `json:"source"`
			Sources  []string `json:"sources"`
		} `json:"cases"`
	}
	require.NoError(t, json.Unmarshal(raw, &suite))
	require.Equal(t, "v0.6", suite.Version)
	require.Len(t, suite.Cases, 19)
	seen := make(map[string]struct{}, len(suite.Cases))
	for _, testCase := range suite.Cases {
		require.NotEmpty(t, testCase.CaseID)
		require.NotEmpty(t, testCase.Question, testCase.CaseID)
		require.NotEmpty(t, testCase.Expected, testCase.CaseID)
		require.True(t, testCase.Source != "" || len(testCase.Sources) > 0, testCase.CaseID)
		_, duplicate := seen[testCase.CaseID]
		require.False(t, duplicate, testCase.CaseID)
		seen[testCase.CaseID] = struct{}{}
	}

	evaluationCases, err := LoadEvaluationCases(filepath.Join("..", "..", "testdata", "ai_eval"))
	require.NoError(t, err)
	evaluationByID := make(map[string]EvaluationCase, len(evaluationCases))
	for _, testCase := range evaluationCases {
		evaluationByID[evaluationCaseID(testCase)] = testCase
	}
	v06EvaluationCases := make([]EvaluationCase, 0, len(seen))
	for _, sourceCase := range suite.Cases {
		caseID := sourceCase.CaseID
		testCase, exists := evaluationByID[caseID]
		require.True(t, exists, "%s 未进入统一评测集", caseID)
		require.Equal(t, EvaluationKindPolicy, testCase.Kind, caseID)
		require.Equal(t, sourceCase.Question, testCase.Question, caseID)
		require.NotEmpty(t, testCase.TargetDocumentTypes, caseID)
		require.NotEmpty(t, testCase.TargetSources, caseID)
		require.NotEmpty(t, testCase.MustContain, caseID)
		require.NotEmpty(t, testCase.MustNotContain, caseID)
		require.NotEmpty(t, testCase.Fixture.Retrieved, caseID)
		v06EvaluationCases = append(v06EvaluationCases, testCase)
	}
	report, err := NewEvaluationRunner("fixture", 5, FixtureEvaluationBackend{}).Run(context.Background(), v06EvaluationCases)
	require.NoError(t, err)
	require.Equal(t, 19, report.Total)
	require.Zero(t, report.Failed)
}
