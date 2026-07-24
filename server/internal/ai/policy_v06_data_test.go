package ai

import (
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
}
