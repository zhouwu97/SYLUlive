package ai

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestValidateCitationsBlocksUnknownChunksAndBuildsServerSources(t *testing.T) {
	chunks := []RetrievedChunk{{
		ChunkID: 18, DocumentID: 3, Title: "学生手册", Department: "学生处",
		SourceURI: "https://example.edu/policy", Content: "请假规定", RRFScore: 0.05,
	}}
	answer, sources, invalid := ValidateCitations("有效规定[chunk:18]，伪造内容[chunk:999]。", chunks)
	require.True(t, invalid)
	require.Contains(t, answer, "[1]")
	require.NotContains(t, answer, "chunk:")
	require.NotContains(t, answer, "[chunk:999]")
	require.Len(t, sources, 1)
	require.Equal(t, "学生手册", sources[0].Title)
	require.Equal(t, "confirmed", sources[0].Confidence)
}

func TestValidateCitationsRejectsGenericSourcePlaceholder(t *testing.T) {
	chunks := []RetrievedChunk{{
		ChunkID: 18, DocumentID: 3, Title: "学生手册", Content: "请假规定", RRFScore: 0.05,
	}}
	_, sources, invalid := ValidateCitations("请按规定办理。[chunk:18] [来源]", chunks)

	require.True(t, invalid)
	require.Len(t, sources, 1)
}

func TestValidateNumberedCitationsRejectsForgeryAndAggregatesByDocument(t *testing.T) {
	effectiveFrom := time.Date(2025, time.September, 1, 0, 0, 0, 0, time.UTC)
	chunks := []RetrievedChunk{
		{
			ChunkID: 18, DocumentID: 3, CitationNumber: 1, Title: "学生手册",
			Department: "学生处", Status: "published", EffectiveFrom: &effectiveFrom,
			SourceLocator: "第十条",
		},
		{ChunkID: 19, DocumentID: 3, CitationNumber: 2, Title: "学生手册", SourceLocator: "第十一条"},
	}
	answer, sources, invalid := ValidateCitations("第一项[1]，第二项[2]。", chunks)
	require.False(t, invalid)
	require.Equal(t, "第一项[1]，第二项[2]。", answer)
	require.Len(t, sources, 1)
	require.Equal(t, []int{1, 2}, sources[0].CitationNumbers)
	require.Equal(t, []string{"第十条", "第十一条"}, sources[0].Locators)
	require.Equal(t, "学生处", sources[0].Department)
	require.Equal(t, "published", sources[0].Status)
	require.Equal(t, effectiveFrom, *sources[0].EffectiveFrom)

	_, _, invalid = ValidateCitations("伪造结论[9]。", chunks)
	require.True(t, invalid)
}

func TestValidateNumberedCitationsAllowsRetrievedSubset(t *testing.T) {
	chunks := []RetrievedChunk{
		{ChunkID: 18, DocumentID: 3, CitationNumber: 1, Title: "学籍管理规定"},
		{ChunkID: 19, DocumentID: 4, CitationNumber: 2, Title: "补考业务口径"},
		{ChunkID: 20, DocumentID: 5, CitationNumber: 3, Title: "课程重修办法"},
	}

	answer, sources, invalid := ValidateCitations(
		"课程未通过后应按规定处理。[1] 成绩记载以课程口径为准。[2]",
		chunks,
	)

	require.False(t, invalid)
	require.Equal(t, "课程未通过后应按规定处理。[1] 成绩记载以课程口径为准。[2]", answer)
	require.Len(t, sources, 2)
	require.Equal(t, []int{1}, sources[0].CitationNumbers)
	require.Equal(t, []int{2}, sources[1].CitationNumbers)
}

func TestValidateNumberedCitationsIgnoresMarkdownNumericLinkLabels(t *testing.T) {
	chunks := []RetrievedChunk{{
		ChunkID: 18, DocumentID: 3, CitationNumber: 1, Title: "学生手册",
	}}

	answer, sources, invalid := ValidateCitations(
		"政策结论[1]，发布年度见[2026](https://example.edu/policy)。",
		chunks,
	)

	require.False(t, invalid)
	require.Equal(t, "政策结论[1]，发布年度见[2026](https://example.edu/policy)。", answer)
	require.Len(t, sources, 1)
}

func TestFormatVectorUsesPgvectorLiteral(t *testing.T) {
	require.Equal(t, "[0.5000000,-0.2500000]", formatVector([]float32{0.5, -0.25}))
}

func TestPreferredDocumentTypeOrderUsesValidNoOpExpression(t *testing.T) {
	order, args := preferredDocumentTypeOrder(nil)
	require.Equal(t, "NULL::integer", order)
	require.Empty(t, args)
}

func TestBuildORFTSQueryUsesGroupedORSemantics(t *testing.T) {
	query := buildORFTSQuery(AnalyzeResult{
		Tokens:       []string{"补考", "成绩", "补考", "？"},
		SearchString: "补考 成绩",
	}, []string{"二次考试", "等级为D或F", "及格 不及格"})

	require.Equal(t, `"补考" OR "成绩" OR "二次考试" OR "等级为D或F" OR "及格" OR "不及格"`, query)
	require.NotContains(t, query, " AND ")
}

func TestPolicyQueryPlanSummaryDoesNotExposeQuestionOrExpandedText(t *testing.T) {
	plan := testPolicyQueryPlan("补考成绩怎么算-仅用于隐私断言")
	encoded, err := json.Marshal(summarizePolicyQueryPlan(plan))
	require.NoError(t, err)
	require.NotContains(t, string(encoded), plan.NormalizedQuery)
	require.NotContains(t, string(encoded), plan.retrievalQuery())
	require.Contains(t, string(encoded), `"intent":"second_exam_grade"`)
}

func TestWeightedFusionMakesExactMatchesStrongerThanTrigramFallback(t *testing.T) {
	plan := testPolicyQueryPlan("如何申请休学")
	exact := policyTestChunk(1, 1, "school_undergraduate_status_policy", "休学规定")
	fuzzy := policyTestChunk(2, 2, "school_competition_course_grade_reward_policy", "竞赛奖励")

	chunks := fuseRankedChunks(plan, []rankedChunkList{
		{Channel: retrievalChannelTrigram, Items: []rankedChunk{{RetrievedChunk: fuzzy, Rank: 1}}},
		{Channel: retrievalChannelExact, Items: []rankedChunk{{RetrievedChunk: exact, Rank: 1}}},
	}, 5)

	require.Len(t, chunks, 2)
	require.Equal(t, exact.ChunkID, chunks[0].ChunkID)
	require.Greater(t, chunks[0].ScoreDetails.Exact, chunks[1].ScoreDetails.Trigram)
	require.Equal(t, chunks[0].RRFScore, chunks[0].ScoreDetails.Total)
}

func TestWeightedFusionPrefersCurrentSchoolFilesAndEnforcesHistoryBoundary(t *testing.T) {
	current := policyTestChunk(10, 10, "school_undergraduate_status_policy", "现行学籍规定")
	historical := policyTestChunk(20, 20, "historical_school_second_exam_policy", "历史二考规定")
	historical.SourceType = "official_historical_compilation"

	allowedPlan := testPolicyQueryPlan("补考成绩怎么算")
	allowed := fuseRankedChunks(allowedPlan, []rankedChunkList{{
		Channel: retrievalChannelFTS,
		Items: []rankedChunk{
			{RetrievedChunk: historical, Rank: 1},
			{RetrievedChunk: current, Rank: 1},
		},
	}}, 5)
	require.Len(t, allowed, 2)
	require.Equal(t, current.ChunkID, allowed[0].ChunkID)
	require.True(t, allowed[1].Historical)
	require.Greater(t, allowed[0].ScoreDetails.VersionPriority, allowed[1].ScoreDetails.VersionPriority)

	generalPlan := testPolicyQueryPlan("如何申请休学")
	currentOnly := fuseRankedChunks(generalPlan, []rankedChunkList{{
		Channel: retrievalChannelVector,
		Items: []rankedChunk{
			{RetrievedChunk: historical, Rank: 1},
			{RetrievedChunk: current, Rank: 2},
		},
	}}, 5)
	require.Len(t, currentOnly, 1)
	require.Equal(t, current.ChunkID, currentOnly[0].ChunkID)
}

func TestWeightedFusionSupportsSingleAvailableChannel(t *testing.T) {
	plan := testPolicyQueryPlan("如何申请休学")
	chunk := policyTestChunk(1, 1, "school_undergraduate_status_policy", "休学规定")

	result := fuseRankedChunks(plan, []rankedChunkList{{
		Channel: retrievalChannelVector,
		Items:   []rankedChunk{{RetrievedChunk: chunk, Rank: 1}},
	}}, 5)

	require.Len(t, result, 1)
	require.Positive(t, result[0].ScoreDetails.Vector)
	require.Zero(t, result[0].ScoreDetails.FTS)
}

func TestPolicyRankingForRequiredColloquialQuestions(t *testing.T) {
	tests := []struct {
		question      string
		exactTypes    []string
		requiredTypes []string
	}{
		{
			question:      "补考成绩怎么算",
			exactTypes:    []string{"historical_school_second_exam_policy", "school_undergraduate_status_policy", "school_undergraduate_retake_policy"},
			requiredTypes: []string{"historical_school_second_exam_policy", "school_undergraduate_status_policy", "school_undergraduate_retake_policy"},
		},
		{
			question:      "挂科怎么办",
			exactTypes:    []string{"school_undergraduate_status_policy", "school_undergraduate_retake_policy", "historical_school_second_exam_policy"},
			requiredTypes: []string{"school_undergraduate_status_policy", "school_undergraduate_retake_policy", "historical_school_second_exam_policy"},
		},
		{
			question:      "实验课挂科",
			exactTypes:    []string{"school_undergraduate_retake_policy", "historical_school_second_exam_policy"},
			requiredTypes: []string{"school_undergraduate_retake_policy", "historical_school_second_exam_policy"},
		},
		{
			question:      "补考没过",
			exactTypes:    []string{"school_undergraduate_retake_policy", "school_undergraduate_status_policy"},
			requiredTypes: []string{"school_undergraduate_retake_policy", "school_undergraduate_status_policy"},
		},
		{
			question:      "刷分",
			exactTypes:    []string{"school_undergraduate_retake_policy"},
			requiredTypes: []string{"school_undergraduate_retake_policy"},
		},
	}

	for _, test := range tests {
		t.Run(test.question, func(t *testing.T) {
			plan := testPolicyQueryPlan(test.question)
			lists := []rankedChunkList{
				policyRankedList(retrievalChannelExact, test.exactTypes...),
				policyRankedList(retrievalChannelFTS,
					"school_policy_reasoning_card",
					"school_undergraduate_status_policy",
					"school_undergraduate_retake_policy",
					"historical_school_second_exam_policy",
				),
				policyRankedList(retrievalChannelVector,
					"school_competition_course_grade_reward_policy",
					"school_undergraduate_status_policy",
				),
			}

			chunks := fuseRankedChunks(plan, lists, 5)
			require.NotEmpty(t, chunks)
			require.NotEqual(t, "school_competition_course_grade_reward_policy", chunks[0].DocumentType)
			topTypes := make([]string, len(chunks))
			for index, chunk := range chunks {
				topTypes[index] = chunk.DocumentType
			}
			for _, requiredType := range test.requiredTypes {
				require.Contains(t, topTypes, requiredType)
			}
		})
	}
}

func TestDiversifyRankedChunksLimitsAdjacentDocumentAndSectionDuplicates(t *testing.T) {
	chunks := []RetrievedChunk{
		policyTestChunk(1, 1, "school_undergraduate_status_policy", "第九条"),
		policyTestChunk(2, 1, "school_undergraduate_status_policy", "第九条"),
		policyTestChunk(3, 1, "school_undergraduate_status_policy", "第十条"),
		policyTestChunk(4, 1, "school_undergraduate_status_policy", "第十一条"),
		policyTestChunk(5, 2, "school_undergraduate_retake_policy", "第三条"),
		policyTestChunk(6, 3, "school_policy_reasoning_card", "术语映射"),
	}

	result := diversifyRankedChunks(chunks, 6)
	require.Len(t, result, 5)
	require.Equal(t, []uint{1, 2, 3}, []uint{result[0].DocumentID, result[1].DocumentID, result[2].DocumentID})
	require.Equal(t, uint64(1), result[0].ChunkID)
	for _, chunk := range result {
		require.NotEqual(t, uint64(2), chunk.ChunkID, "同一文档同一章节的低分块应被去重")
	}
}

func policyRankedList(channel retrievalChannel, documentTypes ...string) rankedChunkList {
	items := make([]rankedChunk, 0, len(documentTypes))
	for index, documentType := range documentTypes {
		chunk := policyChunkForDocumentType(documentType)
		items = append(items, rankedChunk{RetrievedChunk: chunk, Rank: index + 1})
	}
	return rankedChunkList{Channel: channel, Items: items}
}

func policyChunkForDocumentType(documentType string) RetrievedChunk {
	documentIDs := map[string]uint{
		"school_policy_reasoning_card":                  1,
		"school_undergraduate_retake_policy":            2,
		"school_undergraduate_status_policy":            3,
		"historical_school_second_exam_policy":          4,
		"school_competition_course_grade_reward_policy": 5,
	}
	documentID := documentIDs[documentType]
	chunk := policyTestChunk(uint64(documentID*10), documentID, documentType, documentType)
	if strings.HasPrefix(documentType, "historical_") {
		chunk.SourceType = "official_historical_compilation"
	}
	return chunk
}

func policyTestChunk(chunkID uint64, documentID uint, documentType, section string) RetrievedChunk {
	return RetrievedChunk{
		ChunkID: chunkID, DocumentID: documentID, DocumentType: documentType,
		SourceType: "official", Title: documentType, SectionTitle: section,
	}
}

// 测试计划是融合纯函数的固定输入，不复制生产领域解析规则。
func testPolicyQueryPlan(question string) PolicyQueryPlan {
	plan := PolicyQueryPlan{
		SchemaVersion: "1.0", PlannerName: "policy_query_planner", PlannerVersion: "fixture-v1",
		Intent: "general_policy", NormalizedQuery: question, HistoryPolicy: "exclude", VersionBoundary: "current_only",
	}
	if strings.Contains(question, "补考") || strings.Contains(question, "挂科") ||
		strings.Contains(question, "刷分") || strings.Contains(question, "实验课") {
		plan.Intent = "second_exam_and_retake"
		plan.ExactTerms = []string{"二次考试", "二考", "重修"}
		plan.PreferredDocTypes = []string{
			"school_policy_reasoning_card", "school_undergraduate_retake_policy",
			"school_undergraduate_status_policy", "historical_school_second_exam_policy",
		}
		plan.HistoryPolicy = "include_when_required"
		plan.VersionBoundary = "current_preferred_with_history"
		plan.AllowHistorical = true
		if strings.Contains(question, "补考") && strings.Contains(question, "成绩") {
			plan.Intent = "second_exam_grade"
		}
	}
	return plan
}
