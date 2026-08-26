package ai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	PolicyRAGSchemaVersion  = "1.2"
	maxPolicyRAGEventBytes  = 256 << 10
	defaultPolicyMaxSources = 6
)

type PolicyRAGHistoryMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type PolicyRAGInput struct {
	RequestID  string                    `json:"request_id"`
	Question   string                    `json:"question"`
	History    []PolicyRAGHistoryMessage `json:"history,omitempty"`
	MaxSources int                       `json:"max_sources"`
}

type PolicyRAGSource struct {
	SourceID       string `json:"source_id"`
	DocumentID     uint   `json:"document_id"`
	ChunkID        uint64 `json:"chunk_id"`
	CitationNumber int    `json:"citation_number"`
	Title          string `json:"title"`
	Content        string `json:"content"`
	DocumentType   string `json:"document_type,omitempty"`
	Department     string `json:"department,omitempty"`
	SourceURL      string `json:"source_url,omitempty"`
	SectionTitle   string `json:"section_title,omitempty"`
	SourceLocator  string `json:"source_locator,omitempty"`
	Historical     bool   `json:"historical,omitempty"`
}

// PolicyRAGUsage 使用指针区分“值为零”和“协议漏字段”，避免缺失 usage 被当作零成本成功。
type PolicyRAGUsage struct {
	Provider       string `json:"provider"`
	Model          string `json:"model"`
	InputTokens    *int   `json:"input_tokens"`
	OutputTokens   *int   `json:"output_tokens"`
	CacheHitTokens *int   `json:"cache_hit_tokens"`
	Metered        *bool  `json:"metered"`
}

type PolicyRAGResult struct {
	RequestID     string            `json:"request_id"`
	SchemaVersion string            `json:"schema_version"`
	ChainName     string            `json:"chain_name"`
	ChainVersion  string            `json:"chain_version"`
	Status        string            `json:"status"`
	AnswerMode    string            `json:"answer_mode"`
	Answer        string            `json:"answer"`
	Warnings      []string          `json:"warnings"`
	Sources       []PolicyRAGSource `json:"sources"`
	Usage         *PolicyRAGUsage   `json:"usage"`
	DegradedModes []string          `json:"degraded_modes"`
}

type PolicyRAGEvent struct {
	RequestID     string           `json:"request_id"`
	SchemaVersion string           `json:"schema_version"`
	ChainName     string           `json:"chain_name"`
	ChainVersion  string           `json:"chain_version"`
	Sequence      int64            `json:"sequence"`
	Type          string           `json:"type"`
	Timestamp     string           `json:"timestamp"`
	Delta         string           `json:"delta"`
	Result        *PolicyRAGResult `json:"result"`
	ErrorCode     string           `json:"error_code"`
}

type PolicyRAGEventStream interface {
	Next(context.Context) (PolicyRAGEvent, error)
	Close() error
}

// LangChainRAG 同时暴露非流式与流式契约，生产 Runtime 只消费事件流。
// 测试可注入纯内存实现，不需要启动 Python、数据库或真实模型。
type LangChainRAG interface {
	QueryPolicy(context.Context, PolicyRAGInput) (PolicyRAGResult, error)
	StreamPolicy(context.Context, PolicyRAGInput) (PolicyRAGEventStream, error)
}

func (c *RAGClient) QueryPolicy(ctx context.Context, input PolicyRAGInput) (PolicyRAGResult, error) {
	input = normalizePolicyRAGInput(input)
	body, err := json.Marshal(input)
	if err != nil {
		return PolicyRAGResult{}, err
	}
	request, err := c.newPolicyRequest(ctx, "/internal/rag/policy/query", body)
	if err != nil {
		return PolicyRAGResult{}, err
	}
	response, err := c.httpClient.Do(request)
	if err != nil {
		return PolicyRAGResult{}, err
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, maxRAGResponseBytes+1))
	if err != nil {
		return PolicyRAGResult{}, err
	}
	if len(responseBody) > maxRAGResponseBytes {
		return PolicyRAGResult{}, fmt.Errorf("RAG response exceeds limit")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return PolicyRAGResult{}, fmt.Errorf("RAG service returned HTTP %d", response.StatusCode)
	}
	var result PolicyRAGResult
	if err := decodeStrictJSON(responseBody, &result); err != nil {
		return PolicyRAGResult{}, fmt.Errorf("decode policy RAG response: %w", err)
	}
	if err := result.validate(input.RequestID); err != nil {
		return PolicyRAGResult{}, err
	}
	return result, nil
}

func (c *RAGClient) StreamPolicy(ctx context.Context, input PolicyRAGInput) (PolicyRAGEventStream, error) {
	input = normalizePolicyRAGInput(input)
	body, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	request, err := c.newPolicyRequest(ctx, "/internal/rag/policy/query/stream", body)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "text/event-stream")
	response, err := c.httpClient.Do(request)
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		response.Body.Close()
		return nil, fmt.Errorf("RAG stream returned HTTP %d", response.StatusCode)
	}
	if !strings.HasPrefix(strings.ToLower(response.Header.Get("Content-Type")), "text/event-stream") {
		response.Body.Close()
		return nil, fmt.Errorf("invalid RAG stream content type")
	}
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 4096), maxPolicyRAGEventBytes)
	return &httpPolicyRAGEventStream{
		body: response.Body, scanner: scanner, requestID: input.RequestID,
	}, nil
}

func normalizePolicyRAGInput(input PolicyRAGInput) PolicyRAGInput {
	input.RequestID = strings.TrimSpace(input.RequestID)
	input.Question = strings.TrimSpace(input.Question)
	if input.MaxSources == 0 {
		input.MaxSources = defaultPolicyMaxSources
	}
	return input
}

func (c *RAGClient) newPolicyRequest(ctx context.Context, path string, body []byte) (*http.Request, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("X-Internal-Service-Token", c.serviceToken)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Request-ID", requestIDForContext(ctx))
	return request, nil
}

type httpPolicyRAGEventStream struct {
	body       io.ReadCloser
	scanner    *bufio.Scanner
	requestID  string
	eventName  string
	data       strings.Builder
	totalBytes int
	lastSeq    int64
}

func (s *httpPolicyRAGEventStream) Next(ctx context.Context) (PolicyRAGEvent, error) {
	for s.scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return PolicyRAGEvent{}, err
		}
		line := s.scanner.Text()
		s.totalBytes += len(line) + 1
		if s.totalBytes > maxRAGResponseBytes {
			return PolicyRAGEvent{}, fmt.Errorf("RAG stream exceeds limit")
		}
		if line == "" {
			if s.eventName != "policy_rag" || s.data.Len() == 0 {
				s.eventName = ""
				s.data.Reset()
				continue
			}
			var event PolicyRAGEvent
			if err := decodeStrictJSON([]byte(s.data.String()), &event); err != nil {
				return PolicyRAGEvent{}, fmt.Errorf("decode policy RAG event: %w", err)
			}
			s.eventName = ""
			s.data.Reset()
			if err := event.validate(s.requestID, s.lastSeq); err != nil {
				return PolicyRAGEvent{}, err
			}
			s.lastSeq = event.Sequence
			return event, nil
		}
		if strings.HasPrefix(line, "event:") {
			s.eventName = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
			continue
		}
		if strings.HasPrefix(line, "data:") {
			if s.data.Len() > 0 {
				s.data.WriteByte('\n')
			}
			s.data.WriteString(strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
	if err := ctx.Err(); err != nil {
		return PolicyRAGEvent{}, err
	}
	if err := s.scanner.Err(); err != nil {
		return PolicyRAGEvent{}, err
	}
	return PolicyRAGEvent{}, io.EOF
}

func (s *httpPolicyRAGEventStream) Close() error { return s.body.Close() }

func (r PolicyRAGResult) validate(requestID string) error {
	if r.RequestID != requestID || r.SchemaVersion != PolicyRAGSchemaVersion ||
		strings.TrimSpace(r.ChainName) == "" || strings.TrimSpace(r.ChainVersion) == "" ||
		strings.TrimSpace(r.Answer) == "" || r.Usage == nil {
		return fmt.Errorf("invalid policy RAG result")
	}
	if err := r.Usage.validate(r.Status == "completed" || r.Status == "general_completed" || r.Status == "citation_rejected"); err != nil {
		return err
	}
	seenSources := make(map[uint64]struct{}, len(r.Sources))
	seenCitations := make(map[int]struct{}, len(r.Sources))
	for _, source := range r.Sources {
		if source.ChunkID == 0 || source.DocumentID == 0 || source.CitationNumber <= 0 ||
			strings.TrimSpace(source.SourceID) != "R"+strconv.Itoa(source.CitationNumber) || strings.TrimSpace(source.Title) == "" {
			return fmt.Errorf("invalid policy RAG source")
		}
		if _, exists := seenSources[source.ChunkID]; exists {
			return fmt.Errorf("duplicate policy RAG source")
		}
		seenSources[source.ChunkID] = struct{}{}
		if _, exists := seenCitations[source.CitationNumber]; exists {
			return fmt.Errorf("duplicate policy RAG citation number")
		}
		seenCitations[source.CitationNumber] = struct{}{}
	}
	switch r.Status {
	case "completed":
		if r.AnswerMode != "verified_campus" {
			return fmt.Errorf("completed policy RAG result has invalid answer mode")
		}
		if len(r.Sources) == 0 {
			return fmt.Errorf("completed policy RAG result has no sources")
		}
		if _, _, invalid := ValidateCitations(r.Answer, policyRAGSourcesToChunks(r.Sources)); invalid {
			return fmt.Errorf("invalid policy RAG citations")
		}
	case "general_completed":
		if r.AnswerMode != "general_answer" && r.AnswerMode != "guided_gap" {
			return fmt.Errorf("general policy RAG result has invalid answer mode")
		}
		if len(r.Sources) != 0 {
			return fmt.Errorf("general policy RAG result has sources")
		}
	case "insufficient_sources":
		if r.AnswerMode != "guided_gap" {
			return fmt.Errorf("insufficient policy RAG result has invalid answer mode")
		}
		if len(r.Sources) != 0 {
			return fmt.Errorf("insufficient policy RAG result has sources")
		}
	case "citation_rejected":
		if r.AnswerMode != "guided_gap" {
			return fmt.Errorf("citation rejected policy RAG result has invalid answer mode")
		}
		if len(r.Sources) != 0 {
			return fmt.Errorf("citation rejected policy RAG result has sources")
		}
	default:
		return fmt.Errorf("invalid policy RAG status")
	}
	return nil
}

func (u PolicyRAGUsage) validate(completed bool) error {
	if strings.TrimSpace(u.Provider) == "" || strings.TrimSpace(u.Model) == "" ||
		u.InputTokens == nil || u.OutputTokens == nil || u.CacheHitTokens == nil || u.Metered == nil ||
		*u.InputTokens < 0 || *u.OutputTokens < 0 || *u.CacheHitTokens < 0 {
		return fmt.Errorf("invalid policy RAG usage")
	}
	if *u.CacheHitTokens > *u.InputTokens {
		return fmt.Errorf("invalid policy RAG cache usage")
	}
	if completed && (!*u.Metered || *u.InputTokens+*u.OutputTokens <= 0) {
		return fmt.Errorf("completed policy RAG result has invalid usage")
	}
	if !completed && (*u.Metered || *u.InputTokens != 0 || *u.OutputTokens != 0 || *u.CacheHitTokens != 0) {
		return fmt.Errorf("unmetered policy RAG result has token usage")
	}
	return nil
}

func (e PolicyRAGEvent) validate(requestID string, lastSeq int64) error {
	if e.RequestID != requestID || e.SchemaVersion != PolicyRAGSchemaVersion ||
		strings.TrimSpace(e.ChainName) == "" || strings.TrimSpace(e.ChainVersion) == "" ||
		e.Sequence <= lastSeq || strings.TrimSpace(e.Timestamp) == "" {
		return fmt.Errorf("invalid policy RAG event")
	}
	if _, err := time.Parse(time.RFC3339Nano, e.Timestamp); err != nil {
		return fmt.Errorf("invalid policy RAG event timestamp")
	}
	switch e.Type {
	case "planning", "retrieving", "reranking", "generating":
		if e.Delta != "" || e.Result != nil || e.ErrorCode != "" {
			return fmt.Errorf("invalid policy RAG stage event")
		}
	case "token":
		if e.Delta == "" || e.Result != nil || e.ErrorCode != "" {
			return fmt.Errorf("invalid policy RAG token event")
		}
	case "completed":
		if e.Result == nil || e.Delta != "" || e.ErrorCode != "" {
			return fmt.Errorf("invalid policy RAG completed event")
		}
		if e.Result.ChainName != e.ChainName || e.Result.ChainVersion != e.ChainVersion {
			return fmt.Errorf("policy RAG event chain mismatch")
		}
		if err := e.Result.validate(requestID); err != nil {
			return err
		}
	case "failed":
		if strings.TrimSpace(e.ErrorCode) == "" || e.Delta != "" || e.Result != nil {
			return fmt.Errorf("invalid policy RAG failed event")
		}
	default:
		return fmt.Errorf("unknown policy RAG event type")
	}
	return nil
}

func decodeStrictJSON(data []byte, target interface{}) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return fmt.Errorf("trailing JSON data")
	}
	return nil
}

func policyRAGUsageEvent(usage *PolicyRAGUsage) ProviderEvent {
	if usage == nil || usage.InputTokens == nil || usage.OutputTokens == nil || usage.CacheHitTokens == nil {
		return ProviderEvent{}
	}
	return ProviderEvent{
		Type: ProviderEventUsage, InputTokens: *usage.InputTokens,
		OutputTokens: *usage.OutputTokens, CacheHitTokens: *usage.CacheHitTokens,
		UsageAvailable: true,
	}
}

func policyRAGSourcesToChunks(sources []PolicyRAGSource) []RetrievedChunk {
	chunks := make([]RetrievedChunk, 0, len(sources))
	for _, source := range sources {
		chunks = append(chunks, RetrievedChunk{
			ChunkID: source.ChunkID, DocumentID: source.DocumentID, Content: source.Content,
			CitationNumber: source.CitationNumber,
			Title:          source.Title, DocumentType: source.DocumentType, Department: source.Department,
			SourceURI: source.SourceURL, SectionTitle: source.SectionTitle,
			SourceLocator: source.SourceLocator, Historical: source.Historical,
		})
	}
	return chunks
}
