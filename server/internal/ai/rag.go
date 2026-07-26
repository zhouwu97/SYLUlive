package ai

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"
)

var ErrRetrievalUnavailable = errors.New("knowledge retrieval unavailable")

const maxRAGResponseBytes = 8 << 20

type RAGClient struct {
	baseURL      string
	serviceToken string
	httpClient   *http.Client
}

func NewRAGClient(baseURL, serviceToken string, client *http.Client) (*RAGClient, error) {
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil {
		return nil, fmt.Errorf("invalid RAG service URL")
	}
	if strings.TrimSpace(serviceToken) == "" {
		return nil, fmt.Errorf("RAG service token is required")
	}
	if client == nil {
		client = http.DefaultClient
	}
	return &RAGClient{baseURL: parsed.String(), serviceToken: strings.TrimSpace(serviceToken), httpClient: client}, nil
}

type AnalyzeResult struct {
	Tokens       []string `json:"tokens"`
	SearchString string   `json:"search_string"`
	ModelVersion string   `json:"model_version"`
}

type embeddingResponse struct {
	Embeddings   [][]float32 `json:"embeddings"`
	ModelVersion string      `json:"model_version"`
	Dimensions   int         `json:"dimensions"`
}

func (c *RAGClient) Embed(ctx context.Context, text string) ([]float32, string, error) {
	var response embeddingResponse
	if err := c.post(ctx, "/internal/rag/embed", map[string]interface{}{"text": text}, &response); err != nil {
		return nil, "", err
	}
	if len(response.Embeddings) != 1 || response.Dimensions != 1536 || len(response.Embeddings[0]) != 1536 || response.ModelVersion == "" {
		return nil, "", fmt.Errorf("invalid embedding response")
	}
	return response.Embeddings[0], response.ModelVersion, nil
}

func (c *RAGClient) EmbedBatch(ctx context.Context, texts []string) ([][]float32, string, error) {
	var response embeddingResponse
	if len(texts) == 0 {
		return nil, "", nil
	}
	if err := c.post(ctx, "/internal/rag/embed-batch", map[string]interface{}{"texts": texts}, &response); err != nil {
		return nil, "", err
	}
	if len(response.Embeddings) != len(texts) || response.Dimensions != 1536 || response.ModelVersion == "" {
		return nil, "", fmt.Errorf("invalid batch embedding response")
	}
	for _, embedding := range response.Embeddings {
		if len(embedding) != 1536 {
			return nil, "", fmt.Errorf("invalid embedding dimensions")
		}
	}
	return response.Embeddings, response.ModelVersion, nil
}

func (c *RAGClient) Analyze(ctx context.Context, text string) (AnalyzeResult, error) {
	var response AnalyzeResult
	if err := c.post(ctx, "/internal/rag/analyze", map[string]interface{}{"text": text}, &response); err != nil {
		return AnalyzeResult{}, err
	}
	if strings.TrimSpace(response.SearchString) == "" {
		return AnalyzeResult{}, fmt.Errorf("empty analyzed query")
	}
	return response, nil
}

func (c *RAGClient) ParseDocument(ctx context.Context, sourceType, fileName string, content []byte) (string, error) {
	var response struct {
		Text string `json:"text"`
	}
	payload := map[string]interface{}{
		"source_type":    sourceType,
		"file_name":      fileName,
		"content_base64": base64.StdEncoding.EncodeToString(content),
	}
	if err := c.post(ctx, "/internal/rag/parse", payload, &response); err != nil {
		return "", err
	}
	response.Text = strings.TrimSpace(response.Text)
	if response.Text == "" || len(response.Text) > 2<<20 {
		return "", fmt.Errorf("invalid parsed document")
	}
	return response.Text, nil
}

func (c *RAGClient) Health(ctx context.Context) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/health", nil)
	if err != nil {
		return err
	}
	request.Header.Set("X-Internal-Service-Token", c.serviceToken)
	response, err := c.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("RAG health returned HTTP %d", response.StatusCode)
	}
	return nil
}

func (c *RAGClient) post(ctx context.Context, path string, payload interface{}, target interface{}) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("X-Internal-Service-Token", c.serviceToken)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxRAGResponseBytes+1))
	if err != nil {
		return err
	}
	if len(responseBody) > maxRAGResponseBytes {
		return fmt.Errorf("RAG response exceeds limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("RAG service returned HTTP %d", response.StatusCode)
	}
	if err := json.Unmarshal(responseBody, target); err != nil {
		return fmt.Errorf("decode RAG response: %w", err)
	}
	return nil
}

type RetrievedChunk struct {
	ChunkID       uint64     `json:"chunk_id"`
	DocumentID    uint       `json:"document_id"`
	DocumentType  string     `json:"document_type,omitempty"`
	Content       string     `json:"content"`
	Title         string     `json:"title"`
	Department    string     `json:"department,omitempty"`
	SectionTitle  string     `json:"section_title,omitempty"`
	SourceURI     string     `json:"source_url,omitempty"`
	SourceLocator string     `json:"source_locator,omitempty"`
	EffectiveFrom *time.Time `json:"effective_from,omitempty"`
	EffectiveTo   *time.Time `json:"effective_to,omitempty"`
	PublishedAt   *time.Time `json:"published_at,omitempty"`

	// ExactHits 由确定性术语检索填充，用于把命中制度原词的证据排到前面。
	ExactHits  int     `json:"-"`
	RRFScore   float64 `json:"-"`
	ExactScore float64 `json:"-"`
}

type RetrievalResult struct {
	// Plan 记录本次实际使用的制度检索计划，供生成层构造受限提示词。
	Plan          PolicyQueryPlan
	Chunks        []RetrievedChunk
	DegradedModes []string
}

type HybridRetriever struct {
	db           *gorm.DB
	rag          *RAGClient
	modelVersion string
	now          func() time.Time
}

func NewHybridRetriever(db *gorm.DB, rag *RAGClient, modelVersion string) *HybridRetriever {
	return &HybridRetriever{db: db, rag: rag, modelVersion: modelVersion, now: time.Now}
}

type rankedChunk struct {
	RetrievedChunk
	Rank int
}

// rankedList 允许历史资料参与融合但不与现行文件等权，避免过期口径压过现行规则。
type rankedList struct {
	items  []rankedChunk
	weight float64
}

// policyChunkColumns 三条检索路径共用同一组元数据，缺一列就无法按文档类型和版本排序。
const policyChunkColumns = `c.id AS chunk_id, c.document_id, d.document_type, c.content, d.title, d.department,
		       c.section_title, d.source_uri, c.source_locator, d.effective_from, d.effective_to, d.published_at`

// policyChunkHaystack 把标题、文档类型、部门和章节标题一起纳入匹配范围。
// 只匹配正文时，《课程重修管理办法》里写“首次考核不合格”的段落无法被识别为重修文件。
const policyChunkHaystack = `(COALESCE(d.title,'') || ' ' || COALESCE(d.document_type,'') || ' ' ||
		       COALESCE(d.department,'') || ' ' || COALESCE(c.section_title,'') || ' ' ||
		       COALESCE(c.search_tokens,'') || ' ' || c.content)`

const maxExactPolicyTerms = 8

// scopePredicate 把现行文件与历史文件彻底分开检索。
// 历史文件一旦填写了失效日期，混在同一条 SQL 里就永远召不回来。
func (r *HybridRetriever) scopePredicate(historical bool) (string, []interface{}) {
	now := r.now()
	if historical {
		return ` AND ((d.effective_to IS NOT NULL AND d.effective_to < ?) OR d.document_type LIKE 'historical%')`,
			[]interface{}{now}
	}
	return ` AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (d.effective_to IS NULL OR d.effective_to >= ?)
		  AND (d.document_type IS NULL OR d.document_type NOT LIKE 'historical%')`,
		[]interface{}{now, now}
}

func (r *HybridRetriever) Retrieve(ctx context.Context, query string) (RetrievalResult, error) {
	if r.db == nil || r.rag == nil || strings.TrimSpace(query) == "" {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}
	plan := BuildPolicyQueryPlan(query)
	searchQuery := plan.ExpandedQuery
	if strings.TrimSpace(searchQuery) == "" {
		searchQuery = query
	}

	embedding, embeddingVersion, embeddingErr := r.rag.Embed(ctx, searchQuery)
	analyzed, analyzeErr := r.rag.Analyze(ctx, searchQuery)
	if embeddingVersion == "" {
		embeddingVersion = r.modelVersion
	}

	lists := make([]rankedList, 0, 6)
	degraded := make([]string, 0, 3)

	// 确定性术语检索先行：命中“二次考试”“课程重修”等制度原词的证据不应依赖模糊相似度。
	if len(plan.ExactTerms) > 0 {
		if exactRows, err := r.exactPolicySearch(ctx, plan.ExactTerms, false, 40); err == nil {
			lists = append(lists, rankedList{items: exactRows, weight: 1.0})
		} else {
			degraded = append(degraded, "exact")
		}
	}
	if embeddingErr == nil {
		if vectorRows, err := r.vectorSearch(ctx, embedding, embeddingVersion, false, 30); err == nil {
			lists = append(lists, rankedList{items: vectorRows, weight: 1.0})
		} else {
			degraded = append(degraded, "vector")
		}
	} else {
		degraded = append(degraded, "vector")
	}
	if analyzeErr == nil {
		if ftsRows, err := r.ftsSearch(ctx, analyzed.SearchString, false, 30); err == nil {
			lists = append(lists, rankedList{items: ftsRows, weight: 1.0})
		} else {
			degraded = append(degraded, "fts")
		}
	} else {
		degraded = append(degraded, "fts")
	}
	if trigramRows, err := r.trigramSearch(ctx, searchQuery, false, 20); err == nil {
		lists = append(lists, rankedList{items: trigramRows, weight: 1.0})
	} else {
		degraded = append(degraded, "trigram")
	}

	if weight := historicalListWeight(plan.HistoricalMode); weight > 0 {
		if len(plan.ExactTerms) > 0 {
			if rows, err := r.exactPolicySearch(ctx, plan.ExactTerms, true, 16); err == nil {
				lists = append(lists, rankedList{items: rows, weight: weight})
			}
		}
		if embeddingErr == nil {
			if rows, err := r.vectorSearch(ctx, embedding, embeddingVersion, true, 12); err == nil {
				lists = append(lists, rankedList{items: rows, weight: weight})
			}
		}
	}

	if len(lists) == 0 {
		return RetrievalResult{Plan: plan}, ErrRetrievalUnavailable
	}

	chunks := fusePolicyCandidates(lists)
	chunks = selectPolicyCoverage(plan, chunks, policyCoverageLimit)
	return RetrievalResult{Plan: plan, Chunks: chunks, DegradedModes: degraded}, nil
}

func historicalListWeight(mode HistoricalPolicyMode) float64 {
	switch mode {
	case HistoricalPolicyRequired:
		return 0.9
	case HistoricalPolicyFallback:
		return 0.5
	default:
		return 0
	}
}

// fusePolicyCandidates 按加权 RRF 合并各检索路径，并保留最高的精确命中数。
func fusePolicyCandidates(lists []rankedList) []RetrievedChunk {
	byID := make(map[uint64]RetrievedChunk)
	scores := make(map[uint64]float64)
	exactHits := make(map[uint64]int)
	for _, list := range lists {
		weight := list.weight
		if weight <= 0 {
			weight = 1
		}
		for _, item := range list.items {
			existing, found := byID[item.ChunkID]
			if !found || strings.TrimSpace(existing.DocumentType) == "" {
				byID[item.ChunkID] = item.RetrievedChunk
			}
			if item.ExactHits > exactHits[item.ChunkID] {
				exactHits[item.ChunkID] = item.ExactHits
			}
			scores[item.ChunkID] += weight / float64(60+item.Rank)
		}
	}
	chunks := make([]RetrievedChunk, 0, len(byID))
	for id, item := range byID {
		item.RRFScore = scores[id]
		item.ExactHits = exactHits[id]
		item.ExactScore = exactScoreForHits(item.ExactHits)
		chunks = append(chunks, item)
	}
	sort.Slice(chunks, func(i, j int) bool {
		left := chunks[i].RRFScore + chunks[i].ExactScore
		right := chunks[j].RRFScore + chunks[j].ExactScore
		if left == right {
			return chunks[i].ChunkID < chunks[j].ChunkID
		}
		return left > right
	})
	return chunks
}

func exactScoreForHits(hits int) float64 {
	if hits <= 0 {
		return 0
	}
	if hits > 4 {
		hits = 4
	}
	return float64(hits) * 0.006
}

// exactPolicySearch 对标题、文档类型、章节标题、分词和正文做确定性术语匹配。
func (r *HybridRetriever) exactPolicySearch(ctx context.Context, terms []string, historical bool, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("exact search requires PostgreSQL")
	}
	cleaned := make([]string, 0, maxExactPolicyTerms)
	for _, term := range terms {
		term = strings.TrimSpace(term)
		if term == "" {
			continue
		}
		cleaned = append(cleaned, term)
		if len(cleaned) == maxExactPolicyTerms {
			break
		}
	}
	if len(cleaned) == 0 {
		return nil, errors.New("no exact policy terms")
	}
	scoreParts := make([]string, 0, len(cleaned))
	args := make([]interface{}, 0, len(cleaned)+3)
	for _, term := range cleaned {
		scoreParts = append(scoreParts, "(CASE WHEN POSITION(? IN "+policyChunkHaystack+") > 0 THEN 1 ELSE 0 END)")
		args = append(args, term)
	}
	scope, scopeArgs := r.scopePredicate(historical)
	args = append(args, scopeArgs...)
	args = append(args, limit)
	sql := `
		SELECT * FROM (
			SELECT ` + policyChunkColumns + `,
			       (` + strings.Join(scoreParts, " + ") + `) AS exact_hits
			FROM ai_knowledge_chunks c
			JOIN ai_knowledge_documents d ON d.id = c.document_id
			WHERE d.status = 'published' AND d.deleted_at IS NULL` + scope + `
		) AS scored
		WHERE exact_hits > 0
		ORDER BY exact_hits DESC, chunk_id ASC
		LIMIT ?`
	return r.queryRanked(ctx, sql, args...)
}

func (r *HybridRetriever) vectorSearch(ctx context.Context, embedding []float32, version string, historical bool, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("vector search requires PostgreSQL")
	}
	scope, scopeArgs := r.scopePredicate(historical)
	args := append([]interface{}{}, scopeArgs...)
	args = append(args, version, formatVector(embedding), limit)
	return r.queryRanked(ctx, `
		SELECT `+policyChunkColumns+`
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL`+scope+`
		  AND c.embedding_model_version = ?
		ORDER BY c.embedding <=> ?::vector
		LIMIT ?`, args...)
}

func (r *HybridRetriever) ftsSearch(ctx context.Context, query string, historical bool, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("FTS search requires PostgreSQL")
	}
	vector := `to_tsvector('simple', ` + policyChunkHaystack + `)`
	scope, scopeArgs := r.scopePredicate(historical)
	args := append([]interface{}{}, scopeArgs...)
	args = append(args, query, query, limit)
	return r.queryRanked(ctx, `
		SELECT `+policyChunkColumns+`
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL`+scope+`
		  AND `+vector+` @@ plainto_tsquery('simple', ?)
		ORDER BY ts_rank_cd(`+vector+`, plainto_tsquery('simple', ?)) DESC
		LIMIT ?`, args...)
}

func (r *HybridRetriever) trigramSearch(ctx context.Context, query string, historical bool, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("trigram search requires PostgreSQL")
	}
	scope, scopeArgs := r.scopePredicate(historical)
	args := append([]interface{}{}, scopeArgs...)
	args = append(args, query, query, limit)
	return r.queryRanked(ctx, `
		SELECT `+policyChunkColumns+`
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL`+scope+`
		  AND similarity(c.content, ?) > 0.05
		ORDER BY similarity(c.content, ?) DESC
		LIMIT ?`, args...)
}

func (r *HybridRetriever) queryRanked(ctx context.Context, sql string, args ...interface{}) ([]rankedChunk, error) {
	var rows []RetrievedChunk
	if err := r.db.WithContext(ctx).Raw(sql, args...).Scan(&rows).Error; err != nil {
		return nil, err
	}
	result := make([]rankedChunk, len(rows))
	for index, row := range rows {
		result[index] = rankedChunk{RetrievedChunk: row, Rank: index + 1}
	}
	return result, nil
}

func formatVector(values []float32) string {
	var builder strings.Builder
	builder.Grow(len(values) * 8)
	builder.WriteByte('[')
	for index, value := range values {
		if index > 0 {
			builder.WriteByte(',')
		}
		builder.WriteString(strconv.FormatFloat(float64(value), 'f', 7, 32))
	}
	builder.WriteByte(']')
	return builder.String()
}

type SourceCard struct {
	ChunkID     uint64     `json:"chunk_id"`
	DocumentID  uint       `json:"document_id"`
	Title       string     `json:"title"`
	Department  string     `json:"department,omitempty"`
	URL         string     `json:"url,omitempty"`
	Locator     string     `json:"locator,omitempty"`
	PublishedAt *time.Time `json:"published_at,omitempty"`
	Confidence  string     `json:"confidence"`

	// score 只用于合并同一文档的多条引用时保留最高置信度，不对外输出。
	score float64
}

// ValidateCitations 严格删除不在本次召回集合中的引用，并由服务端构造来源卡片。
// 来源卡按 document_id 去重：同一份文件的多个 chunk 合并为一张卡并汇总定位信息，
// 否则一次回答会出现四张标题相同的来源卡。
func ValidateCitations(answer string, chunks []RetrievedChunk) (string, []SourceCard, bool) {
	allowed := make(map[uint64]RetrievedChunk, len(chunks))
	for _, chunk := range chunks {
		allowed[chunk.ChunkID] = chunk
	}
	var output strings.Builder
	cards := make([]SourceCard, 0, len(chunks))
	cardIndex := make(map[uint]int, len(chunks))
	locators := make(map[uint][]string, len(chunks))
	seenChunk := make(map[uint64]struct{}, len(chunks))
	invalid := false
	for index := 0; index < len(answer); {
		start := strings.Index(answer[index:], "[chunk:")
		if start < 0 {
			output.WriteString(answer[index:])
			break
		}
		start += index
		output.WriteString(answer[index:start])
		endOffset := strings.IndexByte(answer[start:], ']')
		if endOffset < 0 {
			output.WriteString(answer[start:])
			break
		}
		end := start + endOffset + 1
		idText := strings.TrimSuffix(strings.TrimPrefix(answer[start:end], "[chunk:"), "]")
		id, err := strconv.ParseUint(idText, 10, 64)
		chunk, ok := allowed[id]
		if err != nil || !ok {
			invalid = true
			index = end
			continue
		}
		output.WriteString(answer[start:end])
		if _, exists := seenChunk[id]; !exists {
			seenChunk[id] = struct{}{}
			mergeSourceCard(&cards, cardIndex, locators, id, chunk)
		}
		index = end
	}
	return output.String(), cards, invalid
}

func mergeSourceCard(
	cards *[]SourceCard,
	cardIndex map[uint]int,
	locators map[uint][]string,
	chunkID uint64,
	chunk RetrievedChunk,
) {
	locator := strings.TrimSpace(chunk.SourceLocator)
	// 没有文档编号的旧数据退回按 chunk 展示，避免全部合并成一张卡。
	if chunk.DocumentID == 0 {
		*cards = append(*cards, SourceCard{
			ChunkID: chunkID, DocumentID: chunk.DocumentID, Title: chunk.Title,
			Department: chunk.Department, URL: chunk.SourceURI, Locator: locator,
			PublishedAt: chunk.PublishedAt, Confidence: confidenceForScore(chunk.RRFScore),
		})
		return
	}
	if index, exists := cardIndex[chunk.DocumentID]; exists {
		if locator != "" && !containsString(locators[chunk.DocumentID], locator) {
			locators[chunk.DocumentID] = append(locators[chunk.DocumentID], locator)
			(*cards)[index].Locator = strings.Join(locators[chunk.DocumentID], "；")
		}
		if confidenceRank(chunk.RRFScore) > confidenceRank((*cards)[index].score) {
			(*cards)[index].Confidence = confidenceForScore(chunk.RRFScore)
			(*cards)[index].score = chunk.RRFScore
		}
		return
	}
	cardIndex[chunk.DocumentID] = len(*cards)
	if locator != "" {
		locators[chunk.DocumentID] = []string{locator}
	}
	*cards = append(*cards, SourceCard{
		ChunkID: chunkID, DocumentID: chunk.DocumentID, Title: chunk.Title,
		Department: chunk.Department, URL: chunk.SourceURI, Locator: locator,
		PublishedAt: chunk.PublishedAt, Confidence: confidenceForScore(chunk.RRFScore),
		score: chunk.RRFScore,
	})
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func confidenceRank(score float64) int {
	switch confidenceForScore(score) {
	case "confirmed":
		return 2
	case "supported":
		return 1
	default:
		return 0
	}
}

func confidenceForScore(score float64) string {
	switch {
	case score >= 0.045:
		return "confirmed"
	case score >= 0.03:
		return "supported"
	default:
		return "partial"
	}
}
