package ai

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func knowledgeBasePath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join("..", "..", "..", "knowledge-base", "sylu-academic-policy", "v0.6", name)
}

func TestV06PolicyRuleCasesAreComplete(t *testing.T) {
	raw, err := os.ReadFile(knowledgeBasePath(t, "SYLUlive_政策规则测试用例_v0.6.json"))
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
	require.Len(t, suite.Cases, 21)
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

func TestV06CurrentMakeupExamPracticeSeparatesBoundariesWithoutFormula(t *testing.T) {
	raw, err := os.ReadFile(knowledgeBasePath(t, "SYLUlive_AI现行补考口径导入_v0.6.json"))
	require.NoError(t, err)
	var document struct {
		DocumentType string `json:"document_type"`
		Content      string `json:"content"`
	}
	require.NoError(t, json.Unmarshal(raw, &document))
	require.Equal(t, DocTypeMakeupExamPractice, document.DocumentType)
	require.Contains(t, document.Content, "补考（也称二次考试、二考）")
	require.Contains(t, document.Content, "和重修是两个不同制度")
	require.Contains(t, document.Content, "不得给出统一的平时成绩与卷面成绩合成比例")
	require.Contains(t, document.Content, "不得自动按普通补考处理")
	// 没有已核验正式文件之前，这份材料不得确立任何补考成绩合成公式。
	require.NotContains(t, document.Content, "补考总成绩 = ")
	require.NotContains(t, document.Content, "沿用上学期")
	require.NotContains(t, document.Content, "等级为D或F")
	require.NotContains(t, document.Content, "绩点为1或0")
}

// TestV06IntentConfigMatchesRuntimePlans 防止 Go 意图与知识库配置再次漂移。
func TestV06IntentConfigMatchesRuntimePlans(t *testing.T) {
	raw, err := os.ReadFile(knowledgeBasePath(t, "SYLUlive_政策问答意图与同义词_v0.6.json"))
	require.NoError(t, err)
	var config struct {
		IntentPriority []string `json:"intent_priority"`
		Intents        []struct {
			Intent                 string     `json:"intent"`
			PreferredDocumentTypes []string   `json:"preferred_document_types"`
			RequiredDocumentGroups [][]string `json:"required_document_groups"`
			HistoricalMode         string     `json:"historical_mode"`
			RequiredAnswerSections []string   `json:"required_answer_sections"`
			UserTerms              []string   `json:"user_terms"`
		} `json:"intents"`
	}
	require.NoError(t, json.Unmarshal(raw, &config))

	configured := make([]string, 0, len(config.Intents))
	for _, intent := range config.Intents {
		configured = append(configured, intent.Intent)
	}
	require.ElementsMatch(t, PolicyIntents(), configured, "Go 意图与知识库意图必须同名同集合")
	require.ElementsMatch(t, PolicyIntents(), config.IntentPriority)

	for _, intent := range config.Intents {
		t.Run(intent.Intent, func(t *testing.T) {
			profile, ok := policyIntentProfiles[intent.Intent]
			require.True(t, ok)
			require.Equal(t, profile.preferredDocTypes, intent.PreferredDocumentTypes)
			require.Equal(t, profile.requiredDocGroups, intent.RequiredDocumentGroups)
			require.Equal(t, string(profile.historicalMode), intent.HistoricalMode)
			require.Equal(t, profile.answerSections, intent.RequiredAnswerSections)
		})
	}
}

// TestV06UserTermsResolveToConfiguredIntent 保证知识库列出的学生口语能落到同一个意图。
func TestV06UserTermsResolveToConfiguredIntent(t *testing.T) {
	cases := map[string]string{
		"挂科":         PolicyIntentFailedCourse,
		"没及格":        PolicyIntentFailedCourse,
		"没拿到学分":      PolicyIntentFailedCourse,
		"补考":         PolicyIntentSecondExam,
		"开学补考":       PolicyIntentSecondExam,
		"二次考试":       PolicyIntentSecondExam,
		"补考成绩怎么算":    PolicyIntentSecondExamGrade,
		"补考绩点":       PolicyIntentSecondExamGrade,
		"重修":         PolicyIntentRetake,
		"刷分":         PolicyIntentRetake,
		"补考没过怎么办":    PolicyIntentRetakeTransition,
		"二考没过":       PolicyIntentRetakeTransition,
		"实验课挂科能补考吗":  PolicyIntentPracticeFailure,
		"课程设计没过怎么办":  PolicyIntentPracticeFailure,
		"实践环节不合格怎么办": PolicyIntentPracticeFailure,
	}
	for question, expected := range cases {
		t.Run(question, func(t *testing.T) {
			require.Equal(t, expected, BuildPolicyQueryPlan(question).Intent)
		})
	}
}
