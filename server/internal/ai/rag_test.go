package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestValidateCitationsBlocksUnknownChunksAndBuildsServerSources(t *testing.T) {
	chunks := []RetrievedChunk{{
		ChunkID: 18, DocumentID: 3, Title: "学生手册", Department: "学生处",
		SourceURI: "https://example.edu/policy", Content: "请假规定", RRFScore: 0.05,
	}}
	answer, sources, invalid := ValidateCitations("有效规定[chunk:18]，伪造内容[chunk:999]。", chunks)
	require.True(t, invalid)
	require.Contains(t, answer, "[chunk:18]")
	require.NotContains(t, answer, "[chunk:999]")
	require.Len(t, sources, 1)
	require.Equal(t, "学生手册", sources[0].Title)
	require.Equal(t, "confirmed", sources[0].Confidence)
}

func TestValidateCitationsMergesSourceCardsPerDocument(t *testing.T) {
	chunks := []RetrievedChunk{
		{ChunkID: 11, DocumentID: 7, Title: "本科生学籍管理规定", SourceLocator: "第九条", RRFScore: 0.02},
		{ChunkID: 12, DocumentID: 7, Title: "本科生学籍管理规定", SourceLocator: "第二十九条", RRFScore: 0.05},
		{ChunkID: 20, DocumentID: 8, Title: "课程重修管理办法", SourceLocator: "关于课程重修第1项", RRFScore: 0.04},
	}
	_, sources, invalid := ValidateCitations(
		"甲[chunk:11]乙[chunk:12]丙[chunk:20]丁[chunk:11]", chunks)
	require.False(t, invalid)
	require.Len(t, sources, 2, "同一份文件只应生成一张来源卡")
	require.Equal(t, uint(7), sources[0].DocumentID)
	require.Equal(t, "第九条；第二十九条", sources[0].Locator)
	require.Equal(t, "confirmed", sources[0].Confidence, "合并后保留最高置信度")
	require.Equal(t, uint(8), sources[1].DocumentID)
	require.Equal(t, "关于课程重修第1项", sources[1].Locator)
}

func TestFormatVectorUsesPgvectorLiteral(t *testing.T) {
	require.Equal(t, "[0.5000000,-0.2500000]", formatVector([]float32{0.5, -0.25}))
}

func TestSelectPolicyCoverageKeepsCurrentStatusAndRetakeForFailedCourseFlow(t *testing.T) {
	// 同一份学籍规定召回四块，重修办法排在最后：只按分数截前六条会丢掉重修分支。
	candidates := []RetrievedChunk{
		{ChunkID: 1, DocumentID: 10, DocumentType: DocTypeStatusPolicy, RRFScore: 0.050},
		{ChunkID: 2, DocumentID: 10, DocumentType: DocTypeStatusPolicy, RRFScore: 0.048},
		{ChunkID: 3, DocumentID: 10, DocumentType: DocTypeStatusPolicy, RRFScore: 0.046},
		{ChunkID: 4, DocumentID: 10, DocumentType: DocTypeStatusPolicy, RRFScore: 0.044},
		{ChunkID: 5, DocumentID: 11, DocumentType: DocTypeHistoricalSecondExam, RRFScore: 0.042},
		{ChunkID: 6, DocumentID: 11, DocumentType: DocTypeHistoricalSecondExam, RRFScore: 0.040},
		{ChunkID: 7, DocumentID: 12, DocumentType: DocTypeRetakePolicy, RRFScore: 0.005},
	}

	selected := selectPolicyCoverage(BuildPolicyQueryPlan("挂科了怎么办"), candidates, policyCoverageLimit)

	types := documentTypesOf(selected)
	require.Contains(t, types, DocTypeStatusPolicy)
	require.Contains(t, types, DocTypeRetakePolicy, "现行重修办法必须进入证据集合")
	require.LessOrEqual(t, countDocument(selected, 10), maxChunksPerPolicyDocument)
	require.GreaterOrEqual(t, distinctPolicyDocuments(selected), minPolicyDocuments)
	require.True(t, isHistoricalDocType(selected[len(selected)-1].DocumentType), "历史文件排在最后")
}

func TestSelectPolicyCoverageDropsHistoryForRetakeQuestions(t *testing.T) {
	candidates := []RetrievedChunk{
		{ChunkID: 5, DocumentID: 11, DocumentType: DocTypeHistoricalSecondExam, RRFScore: 0.090},
		{ChunkID: 7, DocumentID: 12, DocumentType: DocTypeRetakePolicy, RRFScore: 0.010},
		{ChunkID: 8, DocumentID: 13, DocumentType: DocTypeReasoningCard, RRFScore: 0.008},
	}

	selected := selectPolicyCoverage(BuildPolicyQueryPlan("重修有什么规定"), candidates, policyCoverageLimit)

	require.Equal(t, []uint64{7, 8}, chunkIDs(selected))
	require.NotContains(t, documentTypesOf(selected), DocTypeHistoricalSecondExam)
}

func TestSelectPolicyCoverageKeepsHistoryWhenGradeDetailsRequireIt(t *testing.T) {
	candidates := []RetrievedChunk{
		{ChunkID: 1, DocumentID: 10, DocumentType: DocTypeStatusPolicy, RRFScore: 0.050},
		{ChunkID: 2, DocumentID: 13, DocumentType: DocTypeReasoningCard, RRFScore: 0.048},
		{ChunkID: 5, DocumentID: 11, DocumentType: DocTypeHistoricalSecondExam, RRFScore: 0.001},
	}

	selected := selectPolicyCoverage(BuildPolicyQueryPlan("补考成绩怎么算"), candidates, policyCoverageLimit)

	require.Contains(t, documentTypesOf(selected), DocTypeHistoricalSecondExam)
	require.Equal(t, DocTypeHistoricalSecondExam, selected[len(selected)-1].DocumentType)
}

func TestSelectPolicyCoverageLeavesGeneralQueriesUnchanged(t *testing.T) {
	candidates := []RetrievedChunk{
		{ChunkID: 1, DocumentID: 1, DocumentType: "school_leave_policy", RRFScore: 0.05},
		{ChunkID: 2, DocumentID: 2, DocumentType: DocTypeStatusPolicy, RRFScore: 0.04},
	}

	selected := selectPolicyCoverage(BuildPolicyQueryPlan("请假怎么办"), candidates, policyCoverageLimit)

	require.Equal(t, []uint64{1, 2}, chunkIDs(selected))
}

func TestSelectPolicyCoverageKeepsUntypedChunksForLegacyRetrievers(t *testing.T) {
	candidates := []RetrievedChunk{
		{ChunkID: 1, DocumentID: 1, RRFScore: 0.02},
		{ChunkID: 2, DocumentID: 2, RRFScore: 0.03},
	}

	selected := selectPolicyCoverage(BuildPolicyQueryPlan("挂科了怎么办"), candidates, policyCoverageLimit)

	require.Equal(t, []uint64{2, 1}, chunkIDs(selected))
}

func TestEvaluatePolicyEvidenceCoverageReportsMissingGroups(t *testing.T) {
	plan := BuildPolicyQueryPlan("挂科了怎么办")
	coverage := evaluatePolicyEvidenceCoverage(plan, []RetrievedChunk{
		{ChunkID: 1, DocumentID: 10, DocumentType: DocTypeStatusPolicy},
	})
	require.True(t, coverage.HasCurrentStatus)
	require.False(t, coverage.HasCurrentRetake)
	require.False(t, coverage.Satisfied)
	require.Equal(t, [][]string{{DocTypeRetakePolicy}}, coverage.MissingGroups)

	full := evaluatePolicyEvidenceCoverage(plan, []RetrievedChunk{
		{ChunkID: 1, DocumentID: 10, DocumentType: DocTypeStatusPolicy},
		{ChunkID: 2, DocumentID: 12, DocumentType: DocTypeRetakePolicy},
	})
	require.True(t, full.Satisfied)
	require.Empty(t, full.MissingGroups)
}

func TestFusePolicyCandidatesDiscountsHistoricalLists(t *testing.T) {
	current := rankedList{items: []rankedChunk{{
		RetrievedChunk: RetrievedChunk{ChunkID: 1, DocumentType: DocTypeRetakePolicy}, Rank: 1,
	}}, weight: 1}
	historical := rankedList{items: []rankedChunk{{
		RetrievedChunk: RetrievedChunk{ChunkID: 2, DocumentType: DocTypeHistoricalSecondExam}, Rank: 1,
	}}, weight: 0.5}

	fused := fusePolicyCandidates([]rankedList{historical, current})

	require.Equal(t, []uint64{1, 2}, chunkIDs(fused))
	require.Greater(t, fused[0].RRFScore, fused[1].RRFScore)
}

func TestFusePolicyCandidatesKeepsHighestExactHits(t *testing.T) {
	first := rankedList{items: []rankedChunk{{
		RetrievedChunk: RetrievedChunk{ChunkID: 1, ExactHits: 3}, Rank: 1,
	}}, weight: 1}
	second := rankedList{items: []rankedChunk{{
		RetrievedChunk: RetrievedChunk{ChunkID: 1}, Rank: 2,
	}}, weight: 1}

	fused := fusePolicyCandidates([]rankedList{first, second})

	require.Len(t, fused, 1)
	require.Equal(t, 3, fused[0].ExactHits)
	require.InDelta(t, 0.018, fused[0].ExactScore, 1e-9)
}

func chunkIDs(chunks []RetrievedChunk) []uint64 {
	ids := make([]uint64, len(chunks))
	for index, chunk := range chunks {
		ids[index] = chunk.ChunkID
	}
	return ids
}

func documentTypesOf(chunks []RetrievedChunk) []string {
	types := make([]string, len(chunks))
	for index, chunk := range chunks {
		types[index] = chunk.DocumentType
	}
	return types
}

func countDocument(chunks []RetrievedChunk, documentID uint) int {
	count := 0
	for _, chunk := range chunks {
		if chunk.DocumentID == documentID {
			count++
		}
	}
	return count
}
