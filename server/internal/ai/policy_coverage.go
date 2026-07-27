package ai

import (
	"sort"
	"strings"
)

const (
	// policyCoverageLimit 是进入提示词的最大证据条数。
	policyCoverageLimit = 6
	// maxChunksPerPolicyDocument 防止同一份文件占满证据位，挤掉另一条必答分支。
	maxChunksPerPolicyDocument = 2
	// minPolicyDocuments 与知识库 retrieval_rule.minimum_unique_documents 对齐。
	minPolicyDocuments = 2
)

// policyCompositeScore 融合 RRF 名次分、精确命中分和文档类型偏好分。
// 偏好分只做微调，不能压过真实召回名次。
func policyCompositeScore(plan PolicyQueryPlan, chunk RetrievedChunk) float64 {
	return chunk.RRFScore + chunk.ExactScore + float64(policyDocumentPreferenceBonus(plan, chunk.DocumentType))*0.004
}

func docTypeInGroup(docType string, group []string) bool {
	docType = strings.TrimSpace(docType)
	if docType == "" {
		return false
	}
	for _, candidate := range group {
		if candidate == docType {
			return true
		}
	}
	return false
}

func hasTypedChunks(chunks []RetrievedChunk) bool {
	for _, chunk := range chunks {
		if strings.TrimSpace(chunk.DocumentType) != "" {
			return true
		}
	}
	return false
}

// selectPolicyCoverage 分两阶段收敛证据：先综合重排，再按证据组选取。
// 只按分数截前 N 条会出现“同一份学籍规定占满 6 条、现行重修办法一条都没进来”的情况。
func selectPolicyCoverage(plan PolicyQueryPlan, candidates []RetrievedChunk, limit int) []RetrievedChunk {
	if len(candidates) == 0 {
		return nil
	}
	if limit <= 0 {
		limit = policyCoverageLimit
	}
	ranked := append([]RetrievedChunk(nil), candidates...)
	sort.SliceStable(ranked, func(i, j int) bool {
		left := policyCompositeScore(plan, ranked[i])
		right := policyCompositeScore(plan, ranked[j])
		if left == right {
			return ranked[i].ChunkID < ranked[j].ChunkID
		}
		return left > right
	})

	// 旧式自定义召回器与单元测试替身没有文档类型，保留纯分数行为。
	if !plan.IsPolicyIntent() || !hasTypedChunks(ranked) {
		if len(ranked) > limit {
			ranked = ranked[:limit]
		}
		return ranked
	}

	selected := make([]RetrievedChunk, 0, limit)
	perDocument := make(map[uint]int, limit)
	taken := make(map[uint64]struct{}, limit)
	blockHistorical := plan.HistoricalMode == HistoricalPolicyNone

	appendChunk := func(chunk RetrievedChunk) bool {
		if len(selected) >= limit {
			return false
		}
		if _, exists := taken[chunk.ChunkID]; exists {
			return false
		}
		if chunk.DocumentID != 0 && perDocument[chunk.DocumentID] >= maxChunksPerPolicyDocument {
			return false
		}
		taken[chunk.ChunkID] = struct{}{}
		perDocument[chunk.DocumentID]++
		selected = append(selected, chunk)
		return true
	}

	// 阶段一：每个必答证据组至少保留一条最高分证据。
	for _, group := range plan.RequiredDocGroups {
		for _, chunk := range ranked {
			if blockHistorical && isHistoricalDocType(chunk.DocumentType) {
				continue
			}
			if !docTypeInGroup(chunk.DocumentType, group) {
				continue
			}
			if appendChunk(chunk) {
				break
			}
		}
	}

	// 阶段二：历史细节是必答项时，至少保留一条历史证据。
	if plan.HistoricalMode == HistoricalPolicyRequired && !containsHistoricalChunk(selected) {
		for _, chunk := range ranked {
			if isHistoricalDocType(chunk.DocumentType) && appendChunk(chunk) {
				break
			}
		}
	}

	// 阶段三：剩余位置按综合分补齐，每份文件最多两块。
	for _, chunk := range ranked {
		if len(selected) >= limit {
			break
		}
		if blockHistorical && isHistoricalDocType(chunk.DocumentType) {
			continue
		}
		appendChunk(chunk)
	}

	// 阶段四：历史文件排在现行文件之后，避免模型先读到过期口径。
	sort.SliceStable(selected, func(i, j int) bool {
		leftHistorical := isHistoricalDocType(selected[i].DocumentType)
		rightHistorical := isHistoricalDocType(selected[j].DocumentType)
		if leftHistorical != rightHistorical {
			return !leftHistorical
		}
		return policyCompositeScore(plan, selected[i]) > policyCompositeScore(plan, selected[j])
	})
	return selected
}

func containsHistoricalChunk(chunks []RetrievedChunk) bool {
	for _, chunk := range chunks {
		if isHistoricalDocType(chunk.DocumentType) {
			return true
		}
	}
	return false
}

func distinctPolicyDocuments(chunks []RetrievedChunk) int {
	seen := make(map[uint]struct{}, len(chunks))
	for _, chunk := range chunks {
		seen[chunk.DocumentID] = struct{}{}
	}
	return len(seen)
}

// PolicyEvidenceCoverage 记录本次证据集合能支撑哪些必答分支。
// 生成层据此决定哪些结论可以陈述，哪些只能声明缺少正式依据。
type PolicyEvidenceCoverage struct {
	HasCurrentStatus         bool
	HasCurrentRetake         bool
	HasCurrentMakeupPractice bool
	HasReasoningCard         bool
	HasHistoricalSecondExam  bool
	DistinctDocuments        int
	MissingGroups            [][]string
	Satisfied                bool
}

// HasSpecialCourseBoundary 报告是否存在可用于说明实践类课程边界的依据。
func (c PolicyEvidenceCoverage) HasSpecialCourseBoundary() bool {
	return c.HasCurrentRetake || c.HasHistoricalSecondExam
}

func evaluatePolicyEvidenceCoverage(plan PolicyQueryPlan, chunks []RetrievedChunk) PolicyEvidenceCoverage {
	coverage := PolicyEvidenceCoverage{DistinctDocuments: distinctPolicyDocuments(chunks)}
	for _, chunk := range chunks {
		switch strings.TrimSpace(chunk.DocumentType) {
		case DocTypeStatusPolicy:
			coverage.HasCurrentStatus = true
		case DocTypeRetakePolicy:
			coverage.HasCurrentRetake = true
		case DocTypeMakeupExamPractice:
			coverage.HasCurrentMakeupPractice = true
		case DocTypeReasoningCard:
			coverage.HasReasoningCard = true
		case DocTypeHistoricalSecondExam:
			coverage.HasHistoricalSecondExam = true
		}
	}
	for _, group := range plan.RequiredDocGroups {
		satisfied := false
		for _, chunk := range chunks {
			if docTypeInGroup(chunk.DocumentType, group) {
				satisfied = true
				break
			}
		}
		if !satisfied {
			coverage.MissingGroups = append(coverage.MissingGroups, group)
		}
	}
	minimumDocuments := minPolicyDocuments
	if len(plan.RequiredDocGroups) <= 1 {
		minimumDocuments = 1
	}
	coverage.Satisfied = len(coverage.MissingGroups) == 0 && coverage.DistinctDocuments >= minimumDocuments
	return coverage
}

// policyEvidenceLabel 把文档类型翻译成提示词里可读的证据名称。
func policyEvidenceLabel(docType string) string {
	switch strings.TrimSpace(docType) {
	case DocTypeStatusPolicy:
		return "现行学籍管理规定"
	case DocTypeRetakePolicy:
		return "现行课程重修管理办法"
	case DocTypeReasoningCard:
		return "校内规则卡"
	case DocTypeMakeupExamPractice:
		return "现行补考业务口径"
	case DocTypeHistoricalSecondExam:
		return "历史二次考试细则"
	case "":
		return "未标注类型的资料"
	default:
		return docType
	}
}
