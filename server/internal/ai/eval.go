package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	EvaluationKindCitation = "citation"
	EvaluationKindPolicy   = "policy"
)

// EvaluationCase 是引用、检索和生成评测共享的数据契约。
type EvaluationCase struct {
	ID                  string            `json:"id,omitempty"`
	Name                string            `json:"name,omitempty"`
	Kind                string            `json:"kind"`
	Category            string            `json:"category,omitempty"`
	Question            string            `json:"question,omitempty"`
	Answer              string            `json:"answer,omitempty"`
	AllowedChunkIDs     []uint64          `json:"allowed_chunk_ids,omitempty"`
	Arguments           json.RawMessage   `json:"arguments,omitempty"`
	ExpectedValid       bool              `json:"expected_valid"`
	TargetDocumentTypes []string          `json:"target_document_types,omitempty"`
	TargetSources       []string          `json:"target_sources,omitempty"`
	MustContain         []string          `json:"must_contain,omitempty"`
	MustNotContain      []string          `json:"must_not_contain,omitempty"`
	AllowHistorical     bool              `json:"allow_historical"`
	ShouldRefuse        bool              `json:"should_refuse"`
	Fixture             EvaluationFixture `json:"fixture,omitempty"`
}

// EvaluationFixture 保存 CI 可复现的召回结果和生成结果。
type EvaluationFixture struct {
	Retrieved []EvaluationDocument `json:"retrieved,omitempty"`
	Answer    string               `json:"answer,omitempty"`
	Refused   bool                 `json:"refused,omitempty"`
}

// EvaluationDocument 是评测所需的最小证据视图，不包含用户数据。
type EvaluationDocument struct {
	ChunkID       uint64 `json:"chunk_id"`
	DocumentID    uint   `json:"document_id,omitempty"`
	Title         string `json:"title,omitempty"`
	Content       string `json:"content,omitempty"`
	Source        string `json:"source,omitempty"`
	DocumentType  string `json:"document_type,omitempty"`
	Historical    bool   `json:"historical,omitempty"`
	SourceLocator string `json:"source_locator,omitempty"`
}

// EvaluationOutput 是后端生成阶段返回给评估器的统一结果。
type EvaluationOutput struct {
	Answer  string
	Refused bool
}

// EvaluationBackend 隔离 fixture 与 live 依赖。
type EvaluationBackend interface {
	Retrieve(context.Context, EvaluationCase) ([]EvaluationDocument, error)
	Generate(context.Context, EvaluationCase, []EvaluationDocument) (EvaluationOutput, error)
}

// CitationEvaluator 只判断引用是否来自本次召回集合。
type CitationEvaluator interface {
	Evaluate(string, []EvaluationDocument, bool) CitationEvaluation
}

// RetrievalEvaluator 只判断目标文档、来源和历史版本边界。
type RetrievalEvaluator interface {
	Evaluate(EvaluationCase, []EvaluationDocument, int) RetrievalEvaluation
}

// GenerationEvaluator 只判断 must、must_not 和拒答预期。
type GenerationEvaluator interface {
	Evaluate(EvaluationCase, EvaluationOutput) GenerationEvaluation
}

type CitationEvaluation struct {
	Legal   bool     `json:"legal"`
	Reasons []string `json:"reasons,omitempty"`
}

type RetrievalEvaluation struct {
	Passed          bool     `json:"passed"`
	RelevantTotal   int      `json:"relevant_total"`
	RelevantHit     int      `json:"relevant_hit"`
	FirstRelevantAt int      `json:"first_relevant_at,omitempty"`
	Reasons         []string `json:"reasons,omitempty"`
}

type GenerationEvaluation struct {
	Passed          bool     `json:"passed"`
	MustTotal       int      `json:"must_total"`
	MustHit         int      `json:"must_hit"`
	MustNotTotal    int      `json:"must_not_total"`
	MustNotAvoided  int      `json:"must_not_avoided"`
	RefusalExpected bool     `json:"refusal_expected"`
	RefusalCorrect  bool     `json:"refusal_correct"`
	Reasons         []string `json:"reasons,omitempty"`
}

type RateMetric struct {
	Total int     `json:"total"`
	Hit   int     `json:"hit"`
	Rate  float64 `json:"rate"`
}

type RetrievalMetrics struct {
	Cases            int     `json:"cases"`
	RankedCases      int     `json:"ranked_cases"`
	RelevantTargets  int     `json:"relevant_targets"`
	RetrievedTargets int     `json:"retrieved_targets"`
	RecallAtK        float64 `json:"recall_at_k"`
	MRR              float64 `json:"mrr"`
}

type GenerationMetrics struct {
	Cases           int        `json:"cases"`
	MustContain     RateMetric `json:"must_contain"`
	MustNot         RateMetric `json:"must_not"`
	RefusalAccuracy RateMetric `json:"refusal_accuracy"`
}

type CitationMetrics struct {
	Cases            int     `json:"cases"`
	Legal            int     `json:"legal"`
	LegalityRate     float64 `json:"legality_rate"`
	ValidationCases  int     `json:"validation_cases"`
	ValidationPassed int     `json:"validation_passed"`
}

type EvaluationFailure struct {
	CaseID  string   `json:"case_id"`
	Phase   string   `json:"phase"`
	Reasons []string `json:"reasons"`
}

type EvaluationReport struct {
	SchemaVersion string              `json:"schema_version"`
	Mode          string              `json:"mode"`
	K             int                 `json:"k"`
	Total         int                 `json:"total"`
	Passed        int                 `json:"passed"`
	Failed        int                 `json:"failed"`
	Categories    map[string]int      `json:"categories"`
	Retrieval     RetrievalMetrics    `json:"retrieval"`
	Generation    GenerationMetrics   `json:"generation"`
	Citation      CitationMetrics     `json:"citation"`
	Failures      []EvaluationFailure `json:"failures"`
}

// EvaluationRunner 对同一份用例运行分层评测并聚合指标。
type EvaluationRunner struct {
	Mode       string
	K          int
	Backend    EvaluationBackend
	Citation   CitationEvaluator
	Retrieval  RetrievalEvaluator
	Generation GenerationEvaluator
}

// NewEvaluationRunner 建立使用默认评估规则的 Runner。
func NewEvaluationRunner(mode string, k int, backend EvaluationBackend) *EvaluationRunner {
	if k <= 0 {
		k = 5
	}
	return &EvaluationRunner{
		Mode: mode, K: k, Backend: backend,
		Citation: citationRuleEvaluator{}, Retrieval: retrievalRuleEvaluator{}, Generation: generationRuleEvaluator{},
	}
}

// Run 执行评测；失败列表只包含公开用例 ID，不记录问题正文。
func (r *EvaluationRunner) Run(ctx context.Context, cases []EvaluationCase) (EvaluationReport, error) {
	if r == nil || r.Backend == nil || r.Citation == nil || r.Retrieval == nil || r.Generation == nil {
		return EvaluationReport{}, fmt.Errorf("evaluation runner is incomplete")
	}
	report := EvaluationReport{
		SchemaVersion: "1.0", Mode: r.Mode, K: r.K,
		Categories: map[string]int{}, Failures: []EvaluationFailure{},
	}
	var reciprocalRank float64
	for _, testCase := range cases {
		if err := ctx.Err(); err != nil {
			return report, err
		}
		report.Total++
		category := strings.TrimSpace(testCase.Category)
		if category == "" {
			category = testCase.Kind
		}
		report.Categories[category]++

		casePassed := true
		caseID := evaluationCaseID(testCase)
		switch testCase.Kind {
		case EvaluationKindCitation:
			documents := documentsForAllowedChunks(testCase.AllowedChunkIDs)
			citation := r.Citation.Evaluate(testCase.Answer, documents, false)
			report.Citation.ValidationCases++
			if citation.Legal == testCase.ExpectedValid {
				report.Citation.ValidationPassed++
			} else {
				casePassed = false
				report.Failures = append(report.Failures, EvaluationFailure{CaseID: caseID, Phase: "citation", Reasons: citation.Reasons})
			}
		case EvaluationKindPolicy:
			documents, err := r.Backend.Retrieve(ctx, testCase)
			if err != nil {
				casePassed = false
				report.Failures = append(report.Failures, EvaluationFailure{CaseID: caseID, Phase: "retrieval", Reasons: []string{sanitizeEvaluationError(err)}})
				break
			}
			retrieval := r.Retrieval.Evaluate(testCase, documents, r.K)
			report.Retrieval.Cases++
			report.Retrieval.RelevantTargets += retrieval.RelevantTotal
			report.Retrieval.RetrievedTargets += retrieval.RelevantHit
			if retrieval.RelevantTotal > 0 {
				report.Retrieval.RankedCases++
				if retrieval.FirstRelevantAt > 0 {
					reciprocalRank += 1 / float64(retrieval.FirstRelevantAt)
				}
			}
			if !retrieval.Passed {
				casePassed = false
				report.Failures = append(report.Failures, EvaluationFailure{CaseID: caseID, Phase: "retrieval", Reasons: retrieval.Reasons})
			}

			output, err := r.Backend.Generate(ctx, testCase, documents)
			if err != nil {
				casePassed = false
				report.Failures = append(report.Failures, EvaluationFailure{CaseID: caseID, Phase: "generation", Reasons: []string{sanitizeEvaluationError(err)}})
				break
			}
			generation := r.Generation.Evaluate(testCase, output)
			report.Generation.Cases++
			report.Generation.MustContain.Total += generation.MustTotal
			report.Generation.MustContain.Hit += generation.MustHit
			report.Generation.MustNot.Total += generation.MustNotTotal
			report.Generation.MustNot.Hit += generation.MustNotAvoided
			report.Generation.RefusalAccuracy.Total++
			if generation.RefusalCorrect {
				report.Generation.RefusalAccuracy.Hit++
			}
			if !generation.Passed {
				casePassed = false
				report.Failures = append(report.Failures, EvaluationFailure{CaseID: caseID, Phase: "generation", Reasons: generation.Reasons})
			}

			citation := r.Citation.Evaluate(output.Answer, documents, output.Refused)
			report.Citation.Cases++
			if citation.Legal {
				report.Citation.Legal++
			} else {
				casePassed = false
				report.Failures = append(report.Failures, EvaluationFailure{CaseID: caseID, Phase: "citation", Reasons: citation.Reasons})
			}
		default:
			return report, fmt.Errorf("unknown evaluation kind %q for %s", testCase.Kind, caseID)
		}
		if casePassed {
			report.Passed++
		} else {
			report.Failed++
		}
	}

	report.Retrieval.RecallAtK = metricRate(report.Retrieval.RetrievedTargets, report.Retrieval.RelevantTargets)
	if report.Retrieval.RankedCases > 0 {
		report.Retrieval.MRR = reciprocalRank / float64(report.Retrieval.RankedCases)
	}
	report.Generation.MustContain.Rate = metricRate(report.Generation.MustContain.Hit, report.Generation.MustContain.Total)
	report.Generation.MustNot.Rate = metricRate(report.Generation.MustNot.Hit, report.Generation.MustNot.Total)
	report.Generation.RefusalAccuracy.Rate = metricRate(report.Generation.RefusalAccuracy.Hit, report.Generation.RefusalAccuracy.Total)
	report.Citation.LegalityRate = metricRate(report.Citation.Legal, report.Citation.Cases)
	return report, nil
}

// LoadEvaluationCases 按文件名和行号稳定加载 JSONL 评测集。
func LoadEvaluationCases(directory string) ([]EvaluationCase, error) {
	paths, err := filepath.Glob(filepath.Join(directory, "*.jsonl"))
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	cases := make([]EvaluationCase, 0)
	seen := map[string]struct{}{}
	for _, path := range paths {
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		scanner := bufio.NewScanner(file)
		scanner.Buffer(make([]byte, 16<<10), 2<<20)
		line := 0
		for scanner.Scan() {
			line++
			if strings.TrimSpace(scanner.Text()) == "" {
				continue
			}
			candidate, err := isEvaluationCase(scanner.Bytes())
			if err != nil {
				file.Close()
				return nil, fmt.Errorf("%s:%d: %w", path, line, err)
			}
			// 同一目录也存放 A0 的版本化事件 JSONL；它们有独立契约，
			// 不应被当成政策评测用例解析。
			if !candidate {
				continue
			}
			testCase, err := decodeEvaluationCase(scanner.Bytes())
			if err != nil {
				file.Close()
				return nil, fmt.Errorf("%s:%d: %w", path, line, err)
			}
			if err := validateEvaluationCase(testCase); err != nil {
				file.Close()
				return nil, fmt.Errorf("%s:%d: %w", path, line, err)
			}
			id := evaluationCaseID(testCase)
			if _, exists := seen[id]; exists {
				file.Close()
				return nil, fmt.Errorf("%s:%d: duplicate evaluation case %q", path, line, id)
			}
			seen[id] = struct{}{}
			cases = append(cases, testCase)
		}
		scanErr := scanner.Err()
		closeErr := file.Close()
		if scanErr != nil {
			return nil, scanErr
		}
		if closeErr != nil {
			return nil, closeErr
		}
	}
	if len(cases) == 0 {
		return nil, fmt.Errorf("no evaluation cases")
	}
	return cases, nil
}

// isEvaluationCase 判断 JSONL 行是否属于共享评测用例 Schema。
// 事件 fixture 等同目录辅助数据没有 kind 字段，因此由对应采集器单独消费。
func isEvaluationCase(data []byte) (bool, error) {
	var envelope map[string]json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil {
		return false, err
	}
	_, candidate := envelope["kind"]
	return candidate, nil
}

// decodeEvaluationCase 拒绝共享 Schema 之外的字段，防止 Go 与 Python 逐步形成不同语义。
func decodeEvaluationCase(data []byte) (EvaluationCase, error) {
	var testCase EvaluationCase
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&testCase); err != nil {
		return EvaluationCase{}, err
	}
	var trailing interface{}
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return EvaluationCase{}, fmt.Errorf("evaluation case contains multiple JSON values")
		}
		return EvaluationCase{}, err
	}
	return testCase, nil
}

// RunFixedEvaluation 执行不访问网络、结果可复现的 fixture 评测集。
func RunFixedEvaluation(directory string) (EvaluationReport, error) {
	cases, err := LoadEvaluationCases(directory)
	if err != nil {
		return EvaluationReport{}, err
	}
	return NewEvaluationRunner("fixture", 5, FixtureEvaluationBackend{}).Run(context.Background(), cases)
}

// FixtureEvaluationBackend 只读取用例内嵌结果，不访问数据库或网络。
type FixtureEvaluationBackend struct{}

func (FixtureEvaluationBackend) Retrieve(_ context.Context, testCase EvaluationCase) ([]EvaluationDocument, error) {
	return append([]EvaluationDocument(nil), testCase.Fixture.Retrieved...), nil
}

func (FixtureEvaluationBackend) Generate(_ context.Context, testCase EvaluationCase, _ []EvaluationDocument) (EvaluationOutput, error) {
	return EvaluationOutput{Answer: testCase.Fixture.Answer, Refused: testCase.Fixture.Refused}, nil
}

type citationRuleEvaluator struct{}

func (citationRuleEvaluator) Evaluate(answer string, documents []EvaluationDocument, refused bool) CitationEvaluation {
	chunks := make([]RetrievedChunk, len(documents))
	for index, document := range documents {
		chunks[index] = RetrievedChunk{ChunkID: document.ChunkID, DocumentID: document.DocumentID, Title: document.Title}
	}
	_, cards, invalid := ValidateCitations(answer, chunks)
	reasons := []string{}
	if invalid {
		reasons = append(reasons, "answer contains a citation outside the retrieved set")
	}
	if !refused && len(cards) == 0 {
		reasons = append(reasons, "non-refusal answer has no legal citation")
	}
	return CitationEvaluation{Legal: len(reasons) == 0, Reasons: reasons}
}

type retrievalRuleEvaluator struct{}

func (retrievalRuleEvaluator) Evaluate(testCase EvaluationCase, documents []EvaluationDocument, k int) RetrievalEvaluation {
	if k > len(documents) {
		k = len(documents)
	}
	top := documents[:k]
	result := RetrievalEvaluation{Passed: true, Reasons: []string{}}
	targets := testCase.TargetSources
	match := sourceMatches
	if len(targets) == 0 {
		targets = testCase.TargetDocumentTypes
		match = documentTypeMatches
	}
	result.RelevantTotal = len(targets)
	for _, target := range targets {
		found := false
		for rank, document := range top {
			if match(document, target) {
				found = true
				result.RelevantHit++
				if result.FirstRelevantAt == 0 || rank+1 < result.FirstRelevantAt {
					result.FirstRelevantAt = rank + 1
				}
				break
			}
		}
		if !found {
			result.Passed = false
			result.Reasons = append(result.Reasons, "missing target: "+target)
		}
	}
	for _, documentType := range testCase.TargetDocumentTypes {
		found := false
		for _, document := range top {
			if documentTypeMatches(document, documentType) {
				found = true
				break
			}
		}
		if !found {
			result.Passed = false
			result.Reasons = append(result.Reasons, "missing document type: "+documentType)
		}
	}
	if !testCase.AllowHistorical {
		for _, document := range top {
			if document.Historical {
				result.Passed = false
				result.Reasons = append(result.Reasons, "historical document is not allowed")
				break
			}
		}
	}
	return result
}

type generationRuleEvaluator struct{}

func (generationRuleEvaluator) Evaluate(testCase EvaluationCase, output EvaluationOutput) GenerationEvaluation {
	result := GenerationEvaluation{
		Passed: true, MustTotal: len(testCase.MustContain), MustNotTotal: len(testCase.MustNotContain),
		RefusalExpected: testCase.ShouldRefuse, RefusalCorrect: output.Refused == testCase.ShouldRefuse,
		Reasons: []string{},
	}
	for _, expected := range testCase.MustContain {
		if normalizedContains(output.Answer, expected) {
			result.MustHit++
		} else {
			result.Passed = false
			result.Reasons = append(result.Reasons, "missing required text: "+expected)
		}
	}
	for _, forbidden := range testCase.MustNotContain {
		if normalizedContains(output.Answer, forbidden) {
			result.Passed = false
			result.Reasons = append(result.Reasons, "contains forbidden text: "+forbidden)
		} else {
			result.MustNotAvoided++
		}
	}
	if !result.RefusalCorrect {
		result.Passed = false
		result.Reasons = append(result.Reasons, "refusal expectation mismatch")
	}
	return result
}

func validateEvaluationCase(testCase EvaluationCase) error {
	if evaluationCaseID(testCase) == "" {
		return fmt.Errorf("evaluation case id or name is required")
	}
	switch testCase.Kind {
	case EvaluationKindCitation:
		if strings.TrimSpace(testCase.Answer) == "" || len(testCase.AllowedChunkIDs) == 0 {
			return fmt.Errorf("citation case requires answer and allowed_chunk_ids")
		}
	case EvaluationKindPolicy:
		if strings.TrimSpace(testCase.Question) == "" {
			return fmt.Errorf("policy case requires question")
		}
		if !testCase.ShouldRefuse && len(testCase.TargetSources) == 0 && len(testCase.TargetDocumentTypes) == 0 {
			return fmt.Errorf("non-refusal policy case requires a retrieval target")
		}
	default:
		return fmt.Errorf("unknown evaluation kind %q", testCase.Kind)
	}
	return nil
}

func documentsForAllowedChunks(ids []uint64) []EvaluationDocument {
	documents := make([]EvaluationDocument, len(ids))
	for index, id := range ids {
		documents[index] = EvaluationDocument{ChunkID: id, DocumentID: uint(index + 1), Title: "fixture"}
	}
	return documents
}

func evaluationCaseID(testCase EvaluationCase) string {
	if strings.TrimSpace(testCase.ID) != "" {
		return strings.TrimSpace(testCase.ID)
	}
	return strings.TrimSpace(testCase.Name)
}

func sourceMatches(document EvaluationDocument, target string) bool {
	haystack := document.Source + " " + document.Title + " " + document.SourceLocator
	return normalizedContains(haystack, target)
}

func documentTypeMatches(document EvaluationDocument, target string) bool {
	return strings.EqualFold(strings.TrimSpace(document.DocumentType), strings.TrimSpace(target))
}

func normalizedContains(text, expected string) bool {
	return strings.Contains(strings.ToLower(strings.TrimSpace(text)), strings.ToLower(strings.TrimSpace(expected)))
}

func metricRate(hit, total int) float64 {
	if total == 0 {
		return 1
	}
	return float64(hit) / float64(total)
}

func sanitizeEvaluationError(err error) string {
	if err == nil {
		return ""
	}
	// 后端错误只保留类型化摘要，避免把连接串或请求正文写入报告。
	return fmt.Sprintf("%T", err)
}
