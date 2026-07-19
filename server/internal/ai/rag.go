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
	Content       string     `json:"content"`
	Title         string     `json:"title"`
	Department    string     `json:"department,omitempty"`
	SourceURI     string     `json:"source_url,omitempty"`
	SourceLocator string     `json:"source_locator,omitempty"`
	PublishedAt   *time.Time `json:"published_at,omitempty"`
	RRFScore      float64    `json:"-"`
}

type RetrievalResult struct {
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

func (r *HybridRetriever) Retrieve(ctx context.Context, query string) (RetrievalResult, error) {
	if r.db == nil || r.rag == nil || strings.TrimSpace(query) == "" {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}
	embedding, embeddingVersion, embeddingErr := r.rag.Embed(ctx, query)
	analyzed, analyzeErr := r.rag.Analyze(ctx, query)
	if embeddingVersion == "" {
		embeddingVersion = r.modelVersion
	}

	lists := make([][]rankedChunk, 0, 3)
	degraded := make([]string, 0, 2)
	if embeddingErr == nil {
		if vectorRows, err := r.vectorSearch(ctx, embedding, embeddingVersion, 30); err == nil {
			lists = append(lists, vectorRows)
		} else {
			degraded = append(degraded, "vector")
		}
	} else {
		degraded = append(degraded, "vector")
	}
	if analyzeErr == nil {
		if ftsRows, err := r.ftsSearch(ctx, analyzed.SearchString, 30); err == nil {
			lists = append(lists, ftsRows)
		} else {
			degraded = append(degraded, "fts")
		}
	} else {
		degraded = append(degraded, "fts")
	}
	if trigramRows, err := r.trigramSearch(ctx, query, 20); err == nil {
		lists = append(lists, trigramRows)
	} else {
		degraded = append(degraded, "trigram")
	}
	if len(lists) == 0 {
		return RetrievalResult{}, ErrRetrievalUnavailable
	}

	byID := make(map[uint64]RetrievedChunk)
	scores := make(map[uint64]float64)
	for _, list := range lists {
		for _, item := range list {
			byID[item.ChunkID] = item.RetrievedChunk
			scores[item.ChunkID] += 1.0 / float64(60+item.Rank)
		}
	}
	chunks := make([]RetrievedChunk, 0, len(byID))
	for id, item := range byID {
		item.RRFScore = scores[id]
		chunks = append(chunks, item)
	}
	sort.Slice(chunks, func(i, j int) bool {
		if chunks[i].RRFScore == chunks[j].RRFScore {
			return chunks[i].ChunkID < chunks[j].ChunkID
		}
		return chunks[i].RRFScore > chunks[j].RRFScore
	})
	if len(chunks) > 6 {
		chunks = chunks[:6]
	}
	return RetrievalResult{Chunks: chunks, DegradedModes: degraded}, nil
}

func (r *HybridRetriever) vectorSearch(ctx context.Context, embedding []float32, version string, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("vector search requires PostgreSQL")
	}
	vector := formatVector(embedding)
	return r.queryRanked(ctx, `
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.department,
		       d.source_uri, c.source_locator, d.published_at
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (d.effective_to IS NULL OR d.effective_to >= ?)
		  AND c.embedding_model_version = ?
		ORDER BY c.embedding <=> ?::vector
		LIMIT ?`, r.now(), r.now(), version, vector, limit)
}

func (r *HybridRetriever) ftsSearch(ctx context.Context, query string, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("FTS search requires PostgreSQL")
	}
	return r.queryRanked(ctx, `
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.department,
		       d.source_uri, c.source_locator, d.published_at
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (d.effective_to IS NULL OR d.effective_to >= ?)
		  AND to_tsvector('simple', c.search_tokens || ' ' || c.content) @@ plainto_tsquery('simple', ?)
		ORDER BY ts_rank_cd(to_tsvector('simple', c.search_tokens || ' ' || c.content), plainto_tsquery('simple', ?)) DESC
		LIMIT ?`, r.now(), r.now(), query, query, limit)
}

func (r *HybridRetriever) trigramSearch(ctx context.Context, query string, limit int) ([]rankedChunk, error) {
	if r.db.Dialector.Name() != "postgres" {
		return nil, errors.New("trigram search requires PostgreSQL")
	}
	return r.queryRanked(ctx, `
		SELECT c.id AS chunk_id, c.document_id, c.content, d.title, d.department,
		       d.source_uri, c.source_locator, d.published_at
		FROM ai_knowledge_chunks c
		JOIN ai_knowledge_documents d ON d.id = c.document_id
		WHERE d.status = 'published' AND d.deleted_at IS NULL
		  AND (d.effective_from IS NULL OR d.effective_from <= ?)
		  AND (d.effective_to IS NULL OR d.effective_to >= ?)
		  AND similarity(c.content, ?) > 0.05
		ORDER BY similarity(c.content, ?) DESC
		LIMIT ?`, r.now(), r.now(), query, query, limit)
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
}

// ValidateCitations 严格删除不在本次召回集合中的引用，并由服务端构造来源卡片。
func ValidateCitations(answer string, chunks []RetrievedChunk) (string, []SourceCard, bool) {
	allowed := make(map[uint64]RetrievedChunk, len(chunks))
	for _, chunk := range chunks {
		allowed[chunk.ChunkID] = chunk
	}
	var output strings.Builder
	cards := make([]SourceCard, 0, len(chunks))
	seen := make(map[uint64]struct{})
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
		if _, exists := seen[id]; !exists {
			seen[id] = struct{}{}
			cards = append(cards, SourceCard{
				ChunkID: id, DocumentID: chunk.DocumentID, Title: chunk.Title,
				Department: chunk.Department, URL: chunk.SourceURI, Locator: chunk.SourceLocator,
				PublishedAt: chunk.PublishedAt, Confidence: confidenceForScore(chunk.RRFScore),
			})
		}
		index = end
	}
	return output.String(), cards, invalid
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
