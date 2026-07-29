package ai

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func evaluationFixtureDirectory() string {
	return filepath.Join("..", "..", "testdata", "ai_eval")
}

func TestEvaluationFixturesCoverRequiredCategories(t *testing.T) {
	cases, err := LoadEvaluationCases(evaluationFixtureDirectory())
	require.NoError(t, err)
	require.Len(t, cases, 45)

	categories := map[string]int{}
	policyCases := 0
	for _, testCase := range cases {
		categories[testCase.Category]++
		if testCase.Kind == EvaluationKindPolicy {
			policyCases++
			require.NotEmpty(t, testCase.Question, testCase.ID)
			if !testCase.ShouldRefuse {
				require.NotEmpty(t, testCase.TargetDocumentTypes, testCase.ID)
				require.NotEmpty(t, testCase.TargetSources, testCase.ID)
			}
		}
	}
	require.Equal(t, 42, policyCases)
	for _, category := range []string{"typo", "colloquial", "historical_conflict", "prompt_injection", "negative"} {
		require.NotZero(t, categories[category], category)
	}
}

func TestEvaluationJSONSchemaMatchesGoContract(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(evaluationFixtureDirectory(), "schema.json"))
	require.NoError(t, err)
	require.True(t, json.Valid(raw))

	var schema struct {
		ID                   string                     `json:"$id"`
		AdditionalProperties bool                       `json:"additionalProperties"`
		Properties           map[string]json.RawMessage `json:"properties"`
	}
	require.NoError(t, json.Unmarshal(raw, &schema))
	require.Equal(t, "https://shenliyuan.local/schemas/ai-evaluation-case-v1.json", schema.ID)
	require.False(t, schema.AdditionalProperties)

	typeOfCase := reflect.TypeOf(EvaluationCase{})
	goFields := make([]string, 0, typeOfCase.NumField())
	for index := 0; index < typeOfCase.NumField(); index++ {
		name := strings.Split(typeOfCase.Field(index).Tag.Get("json"), ",")[0]
		if name != "" && name != "-" {
			goFields = append(goFields, name)
		}
	}
	require.ElementsMatch(t, goFields, reflectMapKeys(schema.Properties))
}

func TestLoadEvaluationCasesRejectsFieldsOutsideSharedSchema(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "unknown-field.jsonl")
	err := os.WriteFile(path, []byte(`{"id":"case","kind":"policy","question":"问题","should_refuse":true,"fixture":{"refused":true},"python_only":true}`), 0o600)
	require.NoError(t, err)

	_, err = LoadEvaluationCases(directory)
	require.ErrorContains(t, err, "unknown field")
}

func TestFixedEvaluationFixturesPass(t *testing.T) {
	report, err := RunFixedEvaluation(evaluationFixtureDirectory())
	require.NoError(t, err)
	require.Zero(t, report.Failed)
	require.Equal(t, report.Total, report.Passed)
	require.Equal(t, 45, report.Total)
	require.Equal(t, 1.0, report.Retrieval.RecallAtK)
	require.Equal(t, 1.0, report.Retrieval.MRR)
	require.Equal(t, 1.0, report.Citation.LegalityRate)
	require.Equal(t, 1.0, report.Generation.MustContain.Rate)
	require.Equal(t, 1.0, report.Generation.MustNot.Rate)
	require.Equal(t, 1.0, report.Generation.RefusalAccuracy.Rate)
}

func TestEvaluationRunnerReportsLayeredFailuresWithoutQuestion(t *testing.T) {
	testCase := EvaluationCase{
		ID: "private-safe-id", Kind: EvaluationKindPolicy, Category: "test",
		Question:            "不应出现在报告中的完整问题",
		TargetDocumentTypes: []string{"target_type"}, TargetSources: []string{"target_source"},
		MustContain: []string{"必须结论"}, MustNotContain: []string{"禁止结论"},
		Fixture: EvaluationFixture{
			Retrieved: []EvaluationDocument{{ChunkID: 7, DocumentType: "wrong_type", Source: "wrong_source", Historical: true}},
			Answer:    "禁止结论[chunk:999]",
		},
	}
	report, err := NewEvaluationRunner("fixture", 5, FixtureEvaluationBackend{}).Run(context.Background(), []EvaluationCase{testCase})
	require.NoError(t, err)
	require.Equal(t, 1, report.Failed)
	require.Len(t, report.Failures, 3)

	encoded, err := json.Marshal(report)
	require.NoError(t, err)
	require.NotContains(t, string(encoded), testCase.Question)
	require.Contains(t, string(encoded), testCase.ID)
}

func TestEvaluationRunnerSanitizesBackendErrors(t *testing.T) {
	runner := NewEvaluationRunner("live", 5, failingEvaluationBackend{})
	report, err := runner.Run(context.Background(), []EvaluationCase{{
		ID: "backend-error", Kind: EvaluationKindPolicy, Question: "公开测试问题",
		TargetSources: []string{"source"}, TargetDocumentTypes: []string{"type"},
	}})
	require.NoError(t, err)
	require.Equal(t, 1, report.Failed)
	require.NotContains(t, report.Failures[0].Reasons[0], "secret-dsn")
}

type failingEvaluationBackend struct{}

func (failingEvaluationBackend) Retrieve(context.Context, EvaluationCase) ([]EvaluationDocument, error) {
	return nil, errors.New("secret-dsn")
}

func (failingEvaluationBackend) Generate(context.Context, EvaluationCase, []EvaluationDocument) (EvaluationOutput, error) {
	return EvaluationOutput{}, nil
}

func reflectMapKeys(values map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	return keys
}
