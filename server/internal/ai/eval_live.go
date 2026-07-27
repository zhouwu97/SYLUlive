package ai

import (
	"context"
	"fmt"
	"strings"

	"gorm.io/gorm"
)

// EvaluationRetrievalService 允许评测复用生产召回器而不改变其排序逻辑。
type EvaluationRetrievalService interface {
	Retrieve(context.Context, string) (RetrievalResult, error)
}

// LiveEvaluationBackend 显式连接 PostgreSQL、RAG 和真实 Provider。
type LiveEvaluationBackend struct {
	db        *gorm.DB
	retriever EvaluationRetrievalService
	provider  Provider
}

func NewLiveEvaluationBackend(db *gorm.DB, retriever EvaluationRetrievalService, provider Provider) (*LiveEvaluationBackend, error) {
	if db == nil || retriever == nil || provider == nil {
		return nil, fmt.Errorf("live evaluation requires PostgreSQL, RAG retriever and provider")
	}
	return &LiveEvaluationBackend{db: db, retriever: retriever, provider: provider}, nil
}

func (b *LiveEvaluationBackend) Retrieve(ctx context.Context, testCase EvaluationCase) ([]EvaluationDocument, error) {
	result, err := b.retriever.Retrieve(ctx, testCase.Question)
	if err != nil {
		return nil, err
	}
	documentIDs := make([]uint, 0, len(result.Chunks))
	for _, chunk := range result.Chunks {
		documentIDs = append(documentIDs, chunk.DocumentID)
	}
	type documentMetadata struct {
		ID           uint
		DocumentType string
		SourceType   string
		Title        string
	}
	metadata := make([]documentMetadata, 0, len(documentIDs))
	if len(documentIDs) > 0 {
		if err := b.db.WithContext(ctx).Table("ai_knowledge_documents").
			Select("id, document_type, source_type, title").Where("id IN ?", documentIDs).
			Scan(&metadata).Error; err != nil {
			return nil, fmt.Errorf("load evaluation metadata: %w", err)
		}
	}
	byID := make(map[uint]documentMetadata, len(metadata))
	for _, item := range metadata {
		byID[item.ID] = item
	}
	documents := make([]EvaluationDocument, len(result.Chunks))
	for index, chunk := range result.Chunks {
		item := byID[chunk.DocumentID]
		documentType := item.DocumentType
		title := chunk.Title
		if title == "" {
			title = item.Title
		}
		documents[index] = EvaluationDocument{
			ChunkID: chunk.ChunkID, DocumentID: chunk.DocumentID, Title: title,
			Content: chunk.Content, Source: title, DocumentType: documentType,
			Historical:    strings.HasPrefix(documentType, "historical_") || strings.Contains(item.SourceType, "historical"),
			SourceLocator: chunk.SourceLocator,
		}
	}
	return documents, nil
}

func (b *LiveEvaluationBackend) Generate(ctx context.Context, testCase EvaluationCase, documents []EvaluationDocument) (EvaluationOutput, error) {
	if len(documents) == 0 {
		return EvaluationOutput{Answer: "当前已发布资料不足，暂时无法给出可核验回答。", Refused: true}, nil
	}
	chunks := make([]RetrievedChunk, len(documents))
	for index, document := range documents {
		chunks[index] = RetrievedChunk{
			ChunkID: document.ChunkID, DocumentID: document.DocumentID, Title: document.Title,
			Content: document.Content, SourceLocator: document.SourceLocator,
		}
	}
	response, err := b.provider.Chat(ctx, ChatRequest{
		Messages: []Message{
			{Role: "system", Content: policySystemPrompt},
			{Role: "user", Content: buildPolicyPrompt(testCase.Question, chunks)},
		},
		Temperature: 0,
		MaxTokens:   1200,
	})
	if err != nil {
		return EvaluationOutput{}, err
	}
	answer := strings.TrimSpace(response.Content)
	return EvaluationOutput{Answer: answer, Refused: isEvaluationRefusal(answer)}, nil
}

func isEvaluationRefusal(answer string) bool {
	for _, marker := range []string{"资料不足", "无法给出可核验回答", "无法回答", "不能确认"} {
		if strings.Contains(answer, marker) {
			return true
		}
	}
	return false
}
