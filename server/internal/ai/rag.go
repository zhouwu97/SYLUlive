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
	"unicode"
	"unicode/utf8"

	"gorm.io/gorm"
)

var ErrRetrievalUnavailable = errors.New("knowledge retrieval unavailable")

const maxRAGResponseBytes = 8 << 20
const maxKnowledgeChunkResponseBytes = 64 << 20

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
	ModelName    string      `json:"model_name"`
	ModelVersion string      `json:"model_version"`
	Dimensions   int         `json:"dimensions"`
}

func (c *RAGClient) Embed(ctx context.Context, text string) ([]float32, string, int, error) {
	var response embeddingResponse
	if err := c.post(ctx, "/internal/rag/embed", map[string]interface{}{"text": text}, &response); err != nil {
		return nil, "", 0, err
	}
	if len(response.Embeddings) != 1 || response.Dimensions <= 0 || response.Dimensions > 2000 ||
		len(response.Embeddings[0]) != response.Dimensions || response.ModelName == "" || len(response.ModelName) > 255 ||
		response.ModelVersion == "" || len(response.ModelVersion) > 100 {
		return nil, "", 0, fmt.Errorf("invalid embedding response")
	}
	return response.Embeddings[0], response.ModelVersion, response.Dimensions, nil
}

func (c *RAGClient) EmbedBatch(ctx context.Context, texts []string) ([][]float32, string, string, int, error) {
	var response embeddingResponse
	if len(texts) == 0 {
		return nil, "", "", 0, nil
	}
	if err := c.post(ctx, "/internal/rag/embed-batch", map[string]interface{}{"texts": texts}, &response); err != nil {
		return nil, "", "", 0, err
	}
	if len(response.Embeddings) != len(texts) || response.Dimensions <= 0 || response.Dimensions > 2000 ||
		response.ModelName == "" || len(response.ModelName) > 255 || response.ModelVersion == "" || len(response.ModelVersion) > 100 {
		return nil, "", "", 0, fmt.Errorf("invalid batch embedding response")
	}
	for _, embedding := range response.Embeddings {
		if len(embedding) != response.Dimensions {
			return nil, "", "", 0, fmt.Errorf("invalid embedding dimensions")
		}
	}
	return response.Embeddings, response.ModelName, response.ModelVersion, response.Dimensions, nil
}

// KnowledgeChunkRequest 是 Go 写入事务交给 Python LangChain 分块器的只读文档快照。
type KnowledgeChunkRequest struct {
	DocumentID    uint       `json:"document_id"`
	Title         string     `json:"title"`
	Content       string     `json:"content"`
	SourceLocator string     `json:"source_locator,omitempty"`
	DocumentType  string     `json:"document_type,omitempty"`
	Department    string     `json:"department,omitempty"`
	VersionStatus string     `json:"version_status"`
	EffectiveFrom *time.Time `json:"effective_from,omitempty"`
	EffectiveTo   *time.Time `json:"effective_to,omitempty"`
	Aliases       []string   `json:"aliases,omitempty"`
	ChunkSize     int        `json:"chunk_size"`
	ChunkOverlap  int        `json:"chunk_overlap"`
}

type KnowledgeDocumentChunk struct {
	Index         int             `json:"index"`
	Content       string          `json:"content"`
	ContentHash   string          `json:"content_hash"`
	EmbeddingText string          `json:"embedding_text"`
	SectionTitle  string          `json:"section_title"`
	SourceLocator string          `json:"source_locator"`
	Metadata      json.RawMessage `json:"metadata"`
}

type KnowledgeChunkResult struct {
	DocumentID      uint                     `json:"document_id"`
	ChunkingVersion string                   `json:"chunking_version"`
	Chunks          []KnowledgeDocumentChunk `json:"chunks"`
}

func (c *RAGClient) ChunkKnowledgeDocument(ctx context.Context, request KnowledgeChunkRequest) (KnowledgeChunkResult, error) {
	var response KnowledgeChunkResult
	if err := c.postWithLimit(ctx, "/internal/rag/knowledge/chunk", request, &response, maxKnowledgeChunkResponseBytes); err != nil {
		return KnowledgeChunkResult{}, err
	}
	if response.DocumentID != request.DocumentID || strings.TrimSpace(response.ChunkingVersion) == "" ||
		len(response.Chunks) == 0 || len(response.Chunks) > 10000 {
		return KnowledgeChunkResult{}, fmt.Errorf("invalid knowledge chunk response")
	}
	for index, chunk := range response.Chunks {
		if chunk.Index != index || strings.TrimSpace(chunk.Content) == "" || len(chunk.ContentHash) != 64 ||
			strings.TrimSpace(chunk.EmbeddingText) == "" || strings.TrimSpace(chunk.SourceLocator) == "" ||
			len(chunk.Metadata) == 0 || len(chunk.Metadata) > 64<<10 || !json.Valid(chunk.Metadata) {
			return KnowledgeChunkResult{}, fmt.Errorf("invalid knowledge chunk response")
		}
		var metadata map[string]json.RawMessage
		if err := json.Unmarshal(chunk.Metadata, &metadata); err != nil {
			return KnowledgeChunkResult{}, fmt.Errorf("invalid knowledge chunk metadata")
		}
		for _, key := range []string{
			"document_id", "section_title", "section_path", "source_locator", "document_type",
			"department", "version_status", "effective_from", "effective_to", "chunking_version",
		} {
			if _, exists := metadata[key]; !exists {
				return KnowledgeChunkResult{}, fmt.Errorf("incomplete knowledge chunk metadata")
			}
		}
		var metadataDocumentID uint
		var metadataLocator, metadataChunkingVersion string
		if err := json.Unmarshal(metadata["document_id"], &metadataDocumentID); err != nil || metadataDocumentID != request.DocumentID {
			return KnowledgeChunkResult{}, fmt.Errorf("knowledge chunk metadata document mismatch")
		}
		if err := json.Unmarshal(metadata["source_locator"], &metadataLocator); err != nil || metadataLocator != chunk.SourceLocator {
			return KnowledgeChunkResult{}, fmt.Errorf("knowledge chunk metadata locator mismatch")
		}
		if err := json.Unmarshal(metadata["chunking_version"], &metadataChunkingVersion); err != nil || metadataChunkingVersion != response.ChunkingVersion {
			return KnowledgeChunkResult{}, fmt.Errorf("knowledge chunk metadata version mismatch")
		}
	}
	return response, nil
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

// PlanPolicyQuery 调用唯一的 Python 领域规划器，旧 Go 检索链路不再维护意图规则副本。
func (c *RAGClient) PlanPolicyQuery(ctx context.Context, question string) (PolicyQueryPlan, error) {
	var response PolicyQueryPlan
	if err := c.post(ctx, "/internal/rag/policy/plan", map[string]interface{}{"text": question}, &response); err != nil {
		return PolicyQueryPlan{}, err
	}
	if response.SchemaVersion != "1.0" || response.PlannerName != "policy_query_planner" ||
		strings.TrimSpace(response.PlannerVersion) == "" || strings.TrimSpace(response.Intent) == "" ||
		strings.TrimSpace(response.NormalizedQuery) == "" || utf8.RuneCountInString(response.NormalizedQuery) > 300 ||
		len(response.ExactTerms) > 32 || len(response.ExpandedTerms) > 32 || len(response.PreferredDocTypes) > 16 {
		return PolicyQueryPlan{}, fmt.Errorf("invalid policy query plan")
	}
	validHistoryBoundary := response.AllowHistorical && response.HistoryPolicy == "include_when_required" &&
		response.VersionBoundary == "current_preferred_with_history"
	validCurrentBoundary := !response.AllowHistorical && response.HistoryPolicy == "exclude" &&
		response.VersionBoundary == "current_only"
	if !validHistoryBoundary && !validCurrentBoundary {
		return PolicyQueryPlan{}, fmt.Errorf("invalid policy query plan history boundary")
	}
	response.OriginalQuery = strings.TrimSpace(question)
	response.ExpandedQuery = response.retrievalQuery()
	response.Focus = PolicyFocusOverview
	response.Breadth = PolicyBreadthOverview
	if response.AllowHistorical {
		response.HistoricalMode = HistoricalPolicyFallback
	} else {
		response.HistoricalMode = HistoricalPolicyNone
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
	return c.postWithLimit(ctx, path, payload, target, maxRAGResponseBytes)
}

func (c *RAGClient) postWithLimit(ctx context.Context, path string, payload interface{}, target interface{}, responseLimit int64) error {
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
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, responseLimit+1))
	if err != nil {
		return err
	}
	if int64(len(responseBody)) > responseLimit {
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
	ChunkID        uint64                `json:"chunk_id"`
	DocumentID     uint                  `json:"document_id"`
	Content        string                `json:"content"`
	Title          string                `json:"title"`
	DocumentType   string                `json:"document_type,omitempty"`
	SourceType     string                `json:"-"`
	Status         string                `json:"status,omitempty"`
	Department     string                `json:"department,omitempty"`
	SourceURI      string                `json:"source_url,omitempty"`
	SectionTitle   string                `json:"section_title,omitempty"`
	SourceLocator  string                `json:"source_locator,omitempty"`
	EffectiveFrom  *time.Time            `json:"effective_from,omitempty"`
	EffectiveTo    *time.Time            `json:"effective_to,omitempty"`
	PublishedAt    *time.Time            `json:"published_at,omitempty"`
	Historical     bool                  `json:"historical,omitempty"`
	CitationNumber int                   `gorm:"-" json:"-"`
	RRFScore       float64               `gorm:"-" json:"-"`
	ScoreDetails   RetrievalScoreDetails `gorm:"-" json:"score_details,omitempty"`
}

// PolicyQueryPlanSummary 仅保留可审计的规划属性，不包含用户原问题和扩展查询正文。
type PolicyQueryPlanSummary struct {
	Intent                 string   `json:"intent"`
	ExactTermCount         int      `json:"exact_term_count"`
	PreferredDocumentTypes []string `json:"preferred_document_types,omitempty"`
	AllowHistorical        bool     `json:"allow_historical"`
}

// RetrievalScoreDetails 记录每个可复现排序因子的分值。
type RetrievalScoreDetails struct {
	Exact              float64 `json:"exact,omitempty"`
	FTS                float64 `json:"fts,omitempty"`
	Vector             float64 `json:"vector,omitempty"`
	Trigram            float64 `json:"trigram,omitempty"`
	DocumentPreference float64 `json:"document_preference,omitempty"`
	VersionPriority    float64 `json:"version_priority,omitempty"`
	Total              float64 `json:"total"`
}

type RetrievalResult struct {
	// Plan 保留完整检索计划供运行时决策，不进入对外审计载荷。
	Plan          PolicyQueryPlan        `json:"-"`
	Chunks        []RetrievedChunk       `json:"chunks"`
	DegradedModes []string               `json:"degraded_modes,omitempty"`
	QueryPlan     PolicyQueryPlanSummary `json:"query_plan"`
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

type retrievalChannel string

const (
	retrievalChannelExact   retrievalChannel = "exact"
	retrievalChannelFTS     retrievalChannel = "fts"
	retrievalChannelVector  retrievalChannel = "vector"
	retrievalChannelTrigram retrievalChannel = "trigram"

	retrievalRRFBase       = 60.0
	exactChannelWeight     = 3.0
	ftsChannelWeight       = 2.0
	vectorChannelWeight    = 1.25
	trigramChannelWeight   = 0.25
	documentPreferenceUnit = 0.002
	currentSchoolBonus     = 0.004
	currentOfficialBonus   = 0.002
	historicalPenalty      = -0.002
	maxRetrievedChunks     = 6
)

type rankedChunkList struct {
	Channel retrievalChannel
	Items   []rankedChunk
}

func (r *HybridRetriever) Retrieve(ctx context.Context, query string) (RetrievalResult, error) {
	if r.db == nil || r.rag == nil || strings.TrimSpace(query) == "" {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}
	plan, err := r.rag.PlanPolicyQuery(ctx, query)
	if err != nil {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}
	queryText, err := validatedPolicyQueryText(plan)
	if err != nil {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}

	lists := make([]rankedChunkList, 0, 4)
	degraded := make([]string, 0, 4)
	successfulChannels := 0
	if len(plan.ExactTerms) > 0 {
		if rows, searchErr := r.exactSearch(ctx, plan, 30); searchErr == nil {
			lists = append(lists, rankedChunkList{Channel: retrievalChannelExact, Items: rows})
			successfulChannels++
		} else {
			degraded = append(degraded, string(retrievalChannelExact))
		}
	}

	analyzed, analyzeErr := r.rag.Analyze(ctx, queryText)
	if analyzeErr == nil {
		ftsQuery := buildORFTSQuery(analyzed, plan.ExactTerms)
		if ftsQuery != "" {
			if rows, searchErr := r.ftsSearch(ctx, ftsQuery, plan, 30); searchErr == nil {
				lists = append(lists, rankedChunkList{Channel: retrievalChannelFTS, Items: rows})
				successfulChannels++
			} else {
				degraded = append(degraded, string(retrievalChannelFTS))
			}
		} else {
			degraded = append(degraded, string(retrievalChannelFTS))
		}
	} else {
		degraded = append(degraded, string(retrievalChannelFTS))
	}

	embedding, embeddingVersion, embeddingDimensions, embeddingErr := r.rag.Embed(ctx, queryText)
	if embeddingErr == nil {
		if embeddingVersion == "" {
			embeddingVersion = r.modelVersion
		}
		if rows, searchErr := r.vectorSearch(ctx, embedding, embeddingVersion, embeddingDimensions, plan, 30); searchErr == nil {
			lists = append(lists, rankedChunkList{Channel: retrievalChannelVector, Items: rows})
			successfulChannels++
		} else {
			degraded = append(degraded, string(retrievalChannelVector))
		}
	} else {
		degraded = append(degraded, string(retrievalChannelVector))
	}

	// Trigram 只在精确检索与 FTS 候选不足时兜底，不能与高置信通道同权常驻。
	if lexicalCandidateCount(lists) < maxRetrievedChunks {
		if rows, searchErr := r.trigramSearch(ctx, plan.NormalizedQuery, plan, 20); searchErr == nil {
			lists = append(lists, rankedChunkList{Channel: retrievalChannelTrigram, Items: rows})
			successfulChannels++
		} else {
			degraded = append(degraded, string(retrievalChannelTrigram))
		}
	}
	if successfulChannels == 0 {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}

	return RetrievalResult{
		Plan:          plan,
		Chunks:        fuseRankedChunks(plan, lists, maxRetrievedChunks),
		DegradedModes: degraded,
		QueryPlan:     summarizePolicyQueryPlan(plan),
	}, nil
}

func (r *HybridRetriever) exactSearch(ctx context.Context, plan PolicyQueryPlan, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("exact search requires PostgreSQL")
	}
	terms := normalizedExactTerms(plan.ExactTerms)
	if len(terms) == 0 {
		return nil, nil
	}
	orderSQL, orderArgs := preferredDocumentTypeOrder(plan.PreferredDocTypes)
	query := `
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.document_type,
		       d.source_type, d.department, d.source_uri, c.section_title,
		       c.source_locator, d.effective_from, d.effective_to, d.published_at
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		JOIN LATERAL (
			SELECT COALESCE(SUM(CASE
				WHEN position(lower(term) IN lower(concat_ws(' ', d.title, c.section_title,
					c.source_locator, c.metadata ->> 'aliases'))) > 0 THEN 4
				WHEN position(lower(term) IN lower(concat_ws(' ', d.document_type, d.department,
					c.search_tokens))) > 0 THEN 2
				WHEN position(lower(term) IN lower(c.content)) > 0 THEN 1
				ELSE 0 END), 0) AS exact_score
			FROM unnest(string_to_array(CAST(? AS text), E'\n')) AS terms(term)
			WHERE term <> ''
		) term_match ON term_match.exact_score > 0
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (
			(NOT ` + historicalDocumentSQL + ` AND (d.effective_to IS NULL OR d.effective_to >= ?))
			OR (? AND ` + historicalDocumentSQL + `)
		  )
		ORDER BY term_match.exact_score DESC, ` + orderSQL + `, c.id
		LIMIT ?`
	args := []interface{}{strings.Join(terms, "\n"), r.now(), r.now(), plan.AllowHistorical}
	args = append(args, orderArgs...)
	args = append(args, limit)
	return r.queryRanked(ctx, query, args...)
}

func (r *HybridRetriever) vectorSearch(ctx context.Context, embedding []float32, version string, dimensions int, plan PolicyQueryPlan, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("vector search requires PostgreSQL")
	}
	vector := formatVector(embedding)
	distanceSQL := "ce.embedding <=> ?::vector"
	if dimensions == 384 {
		distanceSQL = "ce.embedding::vector(384) <=> ?::vector(384)"
	} else if dimensions == 1536 {
		distanceSQL = "ce.embedding::vector(1536) <=> ?::vector(1536)"
	}
	return r.queryRanked(ctx, `
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.document_type,
		       d.source_type, d.department, d.source_uri, c.section_title,
		       c.source_locator, d.effective_from, d.effective_to, d.published_at
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_chunk_embeddings ce ON ce.chunk_id = c.id
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (
			(NOT `+historicalDocumentSQL+` AND (d.effective_to IS NULL OR d.effective_to >= ?))
			OR (? AND `+historicalDocumentSQL+`)
		  )
		  AND ce.model_version = ?
		  AND ce.dimensions = ?
		ORDER BY `+distanceSQL+`
		LIMIT ?`, r.now(), r.now(), plan.AllowHistorical, version, dimensions, vector, limit)
}

func (r *HybridRetriever) ftsSearch(ctx context.Context, query string, plan PolicyQueryPlan, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("FTS search requires PostgreSQL")
	}
	orderSQL, orderArgs := preferredDocumentTypeOrder(plan.PreferredDocTypes)
	sql := `
		WITH policy_query AS (
			SELECT websearch_to_tsquery('simple', CAST(? AS text)) AS value
		)
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.document_type,
		       d.source_type, d.department, d.source_uri, c.section_title,
		       c.source_locator, d.effective_from, d.effective_to, d.published_at,
		       ts_rank_cd(` + policyFTSVectorSQL + `, policy_query.value) AS lexical_score
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		CROSS JOIN policy_query
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (
			(NOT ` + historicalDocumentSQL + ` AND (d.effective_to IS NULL OR d.effective_to >= ?))
			OR (? AND ` + historicalDocumentSQL + `)
		  )
		  AND ` + policyFTSVectorSQL + ` @@ policy_query.value
		ORDER BY lexical_score DESC, ` + orderSQL + `, c.id
		LIMIT ?`
	args := []interface{}{query, r.now(), r.now(), plan.AllowHistorical}
	args = append(args, orderArgs...)
	args = append(args, limit)
	return r.queryRanked(ctx, sql, args...)
}

func (r *HybridRetriever) trigramSearch(ctx context.Context, query string, plan PolicyQueryPlan, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("trigram search requires PostgreSQL")
	}
	return r.queryRanked(ctx, `
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.document_type,
		       d.source_type, d.department, d.source_uri, c.section_title,
		       c.source_locator, d.effective_from, d.effective_to, d.published_at
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (
			(NOT `+historicalDocumentSQL+` AND (d.effective_to IS NULL OR d.effective_to >= ?))
			OR (? AND `+historicalDocumentSQL+`)
		  )
		  AND similarity(concat_ws(' ', d.title, c.section_title, c.content), ?) > 0.05
		ORDER BY similarity(concat_ws(' ', d.title, c.section_title, c.content), ?) DESC
		LIMIT ?`, r.now(), r.now(), plan.AllowHistorical, query, query, limit)
}

func (r *HybridRetriever) queryRanked(ctx context.Context, sql string, args ...interface{}) ([]rankedChunk, error) {
	var rows []RetrievedChunk
	if err := r.db.WithContext(ctx).Raw(sql, args...).Scan(&rows).Error; err != nil {
		return nil, err
	}
	result := make([]rankedChunk, len(rows))
	for index, row := range rows {
		row.Historical = isHistoricalDocument(row)
		result[index] = rankedChunk{RetrievedChunk: row, Rank: index + 1}
	}
	return result, nil
}

const historicalDocumentSQL = `(left(d.document_type, 11) = 'historical_' OR position('historical' IN lower(d.source_type)) > 0)`

const policyFTSVectorSQL = `(setweight(to_tsvector('simple', concat_ws(' ', d.title, d.document_type,
	d.department, c.section_title, c.source_locator, c.metadata ->> 'aliases')), 'A') ||
	setweight(to_tsvector('simple', coalesce(c.search_tokens, '')), 'B') ||
	setweight(to_tsvector('simple', coalesce(c.content, '')), 'C'))`

func validatedPolicyQueryText(plan PolicyQueryPlan) (string, error) {
	query := strings.Join(strings.Fields(plan.retrievalQuery()), " ")
	if query == "" || !utf8.ValidString(query) || utf8.RuneCountInString(query) > 2048 {
		return "", errors.New("invalid policy retrieval query")
	}
	return query, nil
}

func buildORFTSQuery(analyzed AnalyzeResult, exactTerms []string) string {
	candidates := make([]string, 0, len(analyzed.Tokens)+len(exactTerms))
	candidates = append(candidates, analyzed.Tokens...)
	if len(analyzed.Tokens) == 0 {
		candidates = append(candidates, strings.Fields(analyzed.SearchString)...)
	}
	for _, term := range exactTerms {
		candidates = append(candidates, strings.Fields(term)...)
	}
	seen := make(map[string]struct{}, len(candidates))
	clauses := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(strings.ReplaceAll(candidate, `"`, " "))
		if candidate == "" || !containsSearchCharacter(candidate) {
			continue
		}
		key := strings.ToLower(candidate)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		clauses = append(clauses, `"`+candidate+`"`)
	}
	return strings.Join(clauses, " OR ")
}

func containsSearchCharacter(value string) bool {
	for _, character := range value {
		if unicode.IsLetter(character) || unicode.IsNumber(character) {
			return true
		}
	}
	return false
}

func normalizedExactTerms(terms []string) []string {
	seen := make(map[string]struct{}, len(terms))
	result := make([]string, 0, len(terms))
	for _, term := range terms {
		for _, part := range strings.Fields(strings.ReplaceAll(term, "\n", " ")) {
			part = strings.TrimSpace(part)
			if part == "" {
				continue
			}
			key := strings.ToLower(part)
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			result = append(result, part)
		}
	}
	return result
}

func preferredDocumentTypeOrder(documentTypes []string) (string, []interface{}) {
	if len(documentTypes) == 0 {
		// PostgreSQL 将 ORDER BY 0 解释为 select-list 的第 0 列，
		// 会直接报错；typed NULL 是不改变排序的合法占位表达式。
		return "NULL::integer", nil
	}
	var builder strings.Builder
	builder.WriteString("CASE d.document_type")
	args := make([]interface{}, 0, len(documentTypes))
	for index, documentType := range documentTypes {
		builder.WriteString(" WHEN ? THEN ")
		builder.WriteString(strconv.Itoa(index))
		args = append(args, documentType)
	}
	builder.WriteString(" ELSE ")
	builder.WriteString(strconv.Itoa(len(documentTypes)))
	builder.WriteString(" END")
	return builder.String(), args
}

func summarizePolicyQueryPlan(plan PolicyQueryPlan) PolicyQueryPlanSummary {
	return PolicyQueryPlanSummary{
		Intent: plan.Intent, ExactTermCount: len(plan.ExactTerms),
		PreferredDocumentTypes: append([]string(nil), plan.PreferredDocTypes...),
		AllowHistorical:        plan.AllowHistorical,
	}
}

func lexicalCandidateCount(lists []rankedChunkList) int {
	seen := make(map[uint64]struct{})
	for _, list := range lists {
		if list.Channel != retrievalChannelExact && list.Channel != retrievalChannelFTS {
			continue
		}
		for _, item := range list.Items {
			seen[item.ChunkID] = struct{}{}
		}
	}
	return len(seen)
}

func fuseRankedChunks(plan PolicyQueryPlan, lists []rankedChunkList, limit int) []RetrievedChunk {
	if limit <= 0 {
		return nil
	}
	byID := make(map[uint64]RetrievedChunk)
	for _, list := range lists {
		weight := retrievalChannelWeight(list.Channel)
		if weight == 0 {
			continue
		}
		for index, ranked := range list.Items {
			item := ranked.RetrievedChunk
			item.Historical = isHistoricalDocument(item)
			if item.Historical && !plan.AllowHistorical {
				continue
			}
			rank := ranked.Rank
			if rank <= 0 {
				rank = index + 1
			}
			channelScore := weight / (retrievalRRFBase + float64(rank))
			current, exists := byID[item.ChunkID]
			if !exists {
				current = item
				current.ScoreDetails = RetrievalScoreDetails{}
			}
			addChannelScore(&current.ScoreDetails, list.Channel, channelScore)
			byID[item.ChunkID] = current
		}
	}

	chunks := make([]RetrievedChunk, 0, len(byID))
	for _, item := range byID {
		preference := policyDocumentPreferenceBonus(plan, item.DocumentType)
		if preference > 0 {
			item.ScoreDetails.DocumentPreference = float64(preference) * documentPreferenceUnit
		}
		item.ScoreDetails.VersionPriority = policyVersionPriority(item)
		item.ScoreDetails.Total = item.ScoreDetails.Exact + item.ScoreDetails.FTS +
			item.ScoreDetails.Vector + item.ScoreDetails.Trigram +
			item.ScoreDetails.DocumentPreference + item.ScoreDetails.VersionPriority
		item.RRFScore = item.ScoreDetails.Total
		chunks = append(chunks, item)
	}
	sort.SliceStable(chunks, func(i, j int) bool {
		if chunks[i].RRFScore == chunks[j].RRFScore {
			return chunks[i].ChunkID < chunks[j].ChunkID
		}
		return chunks[i].RRFScore > chunks[j].RRFScore
	})
	return diversifyRankedChunks(chunks, limit)
}

func retrievalChannelWeight(channel retrievalChannel) float64 {
	switch channel {
	case retrievalChannelExact:
		return exactChannelWeight
	case retrievalChannelFTS:
		return ftsChannelWeight
	case retrievalChannelVector:
		return vectorChannelWeight
	case retrievalChannelTrigram:
		return trigramChannelWeight
	default:
		return 0
	}
}

func addChannelScore(details *RetrievalScoreDetails, channel retrievalChannel, score float64) {
	if details == nil {
		return
	}
	switch channel {
	case retrievalChannelExact:
		details.Exact += score
	case retrievalChannelFTS:
		details.FTS += score
	case retrievalChannelVector:
		details.Vector += score
	case retrievalChannelTrigram:
		details.Trigram += score
	}
}

func policyVersionPriority(item RetrievedChunk) float64 {
	if isHistoricalDocument(item) {
		return historicalPenalty
	}
	bonus := 0.0
	if strings.HasPrefix(strings.ToLower(strings.TrimSpace(item.DocumentType)), "school_") {
		bonus += currentSchoolBonus
	}
	if strings.Contains(strings.ToLower(item.SourceType), "official") {
		bonus += currentOfficialBonus
	}
	return bonus
}

func isHistoricalDocument(item RetrievedChunk) bool {
	return item.Historical || strings.HasPrefix(strings.ToLower(strings.TrimSpace(item.DocumentType)), "historical_") ||
		strings.Contains(strings.ToLower(item.SourceType), "historical")
}

func diversifyRankedChunks(chunks []RetrievedChunk, limit int) []RetrievedChunk {
	if limit <= 0 || len(chunks) == 0 {
		return nil
	}
	// 同一文档同一章节只保留最高分块，避免结构化分块的重叠内容重复占位。
	deduplicated := make([]RetrievedChunk, 0, len(chunks))
	seenSections := make(map[string]struct{}, len(chunks))
	for _, chunk := range chunks {
		section := strings.TrimSpace(chunk.SectionTitle)
		if section == "" {
			section = "chunk:" + strconv.FormatUint(chunk.ChunkID, 10)
		}
		key := strconv.FormatUint(uint64(chunk.DocumentID), 10) + "\x00" + section
		if _, exists := seenSections[key]; exists {
			continue
		}
		seenSections[key] = struct{}{}
		deduplicated = append(deduplicated, chunk)
	}
	if limit > len(deduplicated) {
		limit = len(deduplicated)
	}

	selected := make([]RetrievedChunk, 0, limit)
	selectedIDs := make(map[uint64]struct{}, limit)
	documentCounts := make(map[uint]int)
	// 第一轮先取每份文档的最高分块，保证存在多文档证据时不会被相邻块淹没。
	for _, chunk := range deduplicated {
		if len(selected) == limit {
			return selected
		}
		if documentCounts[chunk.DocumentID] > 0 {
			continue
		}
		selected = append(selected, chunk)
		selectedIDs[chunk.ChunkID] = struct{}{}
		documentCounts[chunk.DocumentID]++
	}
	// 第二轮允许每份文档再补一个不同章节。
	for _, chunk := range deduplicated {
		if len(selected) == limit {
			return selected
		}
		if _, exists := selectedIDs[chunk.ChunkID]; exists || documentCounts[chunk.DocumentID] >= 2 {
			continue
		}
		selected = append(selected, chunk)
		selectedIDs[chunk.ChunkID] = struct{}{}
		documentCounts[chunk.DocumentID]++
	}
	// 候选文档不足时再按原始分数补齐，避免无谓缩短证据列表。
	for _, chunk := range deduplicated {
		if len(selected) == limit {
			break
		}
		if _, exists := selectedIDs[chunk.ChunkID]; exists {
			continue
		}
		selected = append(selected, chunk)
		selectedIDs[chunk.ChunkID] = struct{}{}
	}
	return selected
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
	PrimaryChunkID  uint64     `json:"primary_chunk_id,omitempty"`
	DocumentID      uint       `json:"document_id"`
	Title           string     `json:"title"`
	Department      string     `json:"department,omitempty"`
	Status          string     `json:"status"`
	URL             string     `json:"url,omitempty"`
	Locators        []string   `json:"locators,omitempty"`
	CitationNumbers []int      `json:"citation_numbers"`
	EffectiveFrom   *time.Time `json:"effective_from,omitempty"`
	EffectiveTo     *time.Time `json:"effective_to,omitempty"`
	PublishedAt     *time.Time `json:"published_at,omitempty"`
	Confidence      string     `json:"confidence"`
}

// ValidateCitations 校验结构化数字引用；旧链路的 chunk 引用会被转换成公开编号。
func ValidateCitations(answer string, chunks []RetrievedChunk) (string, []SourceCard, bool) {
	structured := false
	for _, chunk := range chunks {
		if chunk.CitationNumber > 0 {
			structured = true
			break
		}
	}
	if structured {
		return validateNumberedCitations(answer, chunks)
	}
	return validateLegacyChunkCitations(answer, chunks)
}

func validateLegacyChunkCitations(answer string, chunks []RetrievedChunk) (string, []SourceCard, bool) {
	allowed := make(map[uint64]RetrievedChunk, len(chunks))
	for _, chunk := range chunks {
		allowed[chunk.ChunkID] = chunk
	}
	var output strings.Builder
	cited := make([]RetrievedChunk, 0, len(chunks))
	numberByChunk := make(map[uint64]int, len(chunks))
	// “[来源]” 这类笼统占位符无法对应具体证据，不能作为可核验引用
	// 写入历史会话；否则客户端既不能编号，也无法展示正确的来源卡片。
	invalid := containsGenericCitationPlaceholder(answer)
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
			invalid = true
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
		number, exists := numberByChunk[id]
		if !exists {
			number = len(numberByChunk) + 1
			numberByChunk[id] = number
			chunk.CitationNumber = number
			cited = append(cited, chunk)
		}
		output.WriteString("[" + strconv.Itoa(number) + "]")
		index = end
	}
	return output.String(), aggregateSourceCards(cited), invalid
}

func validateNumberedCitations(answer string, chunks []RetrievedChunk) (string, []SourceCard, bool) {
	allowed := make(map[int]RetrievedChunk, len(chunks))
	invalid := strings.Contains(strings.ToLower(answer), "[chunk:") ||
		strings.Contains(answer, "[R") ||
		containsGenericCitationPlaceholder(answer)
	for _, chunk := range chunks {
		if chunk.CitationNumber <= 0 {
			invalid = true
			continue
		}
		if _, exists := allowed[chunk.CitationNumber]; exists {
			invalid = true
		}
		allowed[chunk.CitationNumber] = chunk
	}

	seen := make(map[int]struct{}, len(allowed))
	cited := make([]RetrievedChunk, 0, len(allowed))
	for index := 0; index < len(answer); {
		startOffset := strings.IndexByte(answer[index:], '[')
		if startOffset < 0 {
			break
		}
		start := index + startOffset
		endOffset := strings.IndexByte(answer[start:], ']')
		if endOffset < 0 {
			break
		}
		end := start + endOffset
		if end+1 < len(answer) && answer[end+1] == '(' {
			// Markdown 数字链接标签不是政策引用，例如 [2026](https://example.edu)。
			index = end + 1
			continue
		}
		number, err := strconv.Atoi(answer[start+1 : end])
		if err == nil {
			chunk, ok := allowed[number]
			if !ok {
				invalid = true
			} else if _, exists := seen[number]; !exists {
				seen[number] = struct{}{}
				cited = append(cited, chunk)
			}
		}
		index = end + 1
	}
	if len(seen) == 0 || len(seen) != len(allowed) {
		invalid = true
	}
	return answer, aggregateSourceCards(cited), invalid
}

func containsGenericCitationPlaceholder(answer string) bool {
	lower := strings.ToLower(answer)
	return strings.Contains(answer, "[来源]") || strings.Contains(lower, "[source]")
}

func aggregateSourceCards(chunks []RetrievedChunk) []SourceCard {
	cards := make([]SourceCard, 0, len(chunks))
	indexByDocument := make(map[uint]int, len(chunks))
	for _, chunk := range chunks {
		index, exists := indexByDocument[chunk.DocumentID]
		if !exists {
			index = len(cards)
			indexByDocument[chunk.DocumentID] = index
			cards = append(cards, SourceCard{
				PrimaryChunkID: chunk.ChunkID, DocumentID: chunk.DocumentID, Title: chunk.Title,
				Department: chunk.Department, Status: chunk.Status, URL: chunk.SourceURI,
				EffectiveFrom: chunk.EffectiveFrom, EffectiveTo: chunk.EffectiveTo,
				PublishedAt: chunk.PublishedAt,
				Confidence:  confidenceForScore(chunk.RRFScore),
			})
		}
		card := &cards[index]
		if chunk.CitationNumber > 0 && !containsInt(card.CitationNumbers, chunk.CitationNumber) {
			card.CitationNumbers = append(card.CitationNumbers, chunk.CitationNumber)
		}
		if chunk.SourceLocator != "" && !containsString(card.Locators, chunk.SourceLocator) {
			card.Locators = append(card.Locators, chunk.SourceLocator)
		}
		confidence := confidenceForScore(chunk.RRFScore)
		if confidence == "confirmed" || card.Confidence == "partial" && confidence == "supported" {
			card.Confidence = confidence
		}
	}
	return cards
}

func containsInt(values []int, target int) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
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
