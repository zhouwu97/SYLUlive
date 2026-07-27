package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

const (
	knowledgeJobQueued    = "queued"
	knowledgeJobRunning   = "running"
	knowledgeJobCompleted = "completed"
	knowledgeJobFailed    = "failed"
)

type KnowledgeIngestionWorker struct {
	db           *gorm.DB
	rag          *ai.RAGClient
	modelVersion string
	interval     time.Duration
}

func NewKnowledgeIngestionWorker(db *gorm.DB, rag *ai.RAGClient, modelVersion string) *KnowledgeIngestionWorker {
	return &KnowledgeIngestionWorker{db: db, rag: rag, modelVersion: modelVersion, interval: 3 * time.Second}
}

func EnqueueKnowledgeIngestion(tx *gorm.DB, documentID uint, restoreStatuses ...string) (*models.AIKnowledgeIngestionJob, error) {
	if tx == nil || documentID == 0 {
		return nil, errors.New("invalid knowledge ingestion target")
	}
	var existing models.AIKnowledgeIngestionJob
	err := tx.Where("document_id = ? AND status IN ?", documentID, []string{knowledgeJobQueued, knowledgeJobRunning}).
		Order("created_at DESC").First(&existing).Error
	if err == nil {
		return &existing, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}
	restoreStatus := models.KnowledgeStatusInspected
	if len(restoreStatuses) > 0 && restoreStatuses[0] == models.KnowledgeStatusPublished {
		restoreStatus = models.KnowledgeStatusPublished
	}
	job := models.AIKnowledgeIngestionJob{
		ID: uuid.NewString(), DocumentID: documentID, Status: knowledgeJobQueued,
		RestoreStatus: restoreStatus, NotBefore: time.Now(),
	}
	if err := tx.Create(&job).Error; err != nil {
		return nil, err
	}
	return &job, nil
}

func (w *KnowledgeIngestionWorker) Start(ctx context.Context) {
	if w == nil || w.db == nil || w.rag == nil {
		return
	}
	ticker := time.NewTicker(w.interval)
	defer ticker.Stop()
	for {
		for {
			processed, _ := w.ProcessNext(ctx)
			if !processed {
				break
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (w *KnowledgeIngestionWorker) ProcessNext(ctx context.Context) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	var job models.AIKnowledgeIngestionJob
	err := w.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		query := tx.Where("status = ? AND not_before <= ?", knowledgeJobQueued, time.Now()).Order("created_at ASC")
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE", Options: "SKIP LOCKED"})
		}
		var jobs []models.AIKnowledgeIngestionJob
		if err := query.Limit(1).Find(&jobs).Error; err != nil {
			return err
		}
		if len(jobs) == 0 {
			return gorm.ErrRecordNotFound
		}
		job = jobs[0]
		now := time.Now()
		result := tx.Model(&models.AIKnowledgeIngestionJob{}).
			Where("id = ? AND status = ?", job.ID, knowledgeJobQueued).
			Updates(map[string]interface{}{"status": knowledgeJobRunning, "attempt": gorm.Expr("attempt + 1"), "started_at": now, "updated_at": now})
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected != 1 {
			return gorm.ErrRecordNotFound
		}
		if job.RestoreStatus == models.KnowledgeStatusPublished {
			return nil
		}
		return tx.Model(&models.AIKnowledgeDocument{}).Where("id = ?", job.DocumentID).Update("status", models.KnowledgeStatusIndexing).Error
	})
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	job.Attempt++
	if err := w.process(ctx, &job); err != nil {
		w.failJob(job, err)
		return true, err
	}
	return true, nil
}

type preparedKnowledgeChunk struct {
	index         int
	content       string
	contentHash   string
	searchTokens  string
	sectionTitle  string
	sourceLocator string
	metadata      []byte
	embedding     []float32
}

type knowledgeChunkMetadata struct {
	ChunkingVersion string   `json:"chunking_version"`
	DocumentTitle   string   `json:"document_title"`
	DocumentType    string   `json:"document_type,omitempty"`
	Department      string   `json:"department,omitempty"`
	SectionTitle    string   `json:"section_title,omitempty"`
	SectionPath     []string `json:"section_path,omitempty"`
	SourceLocator   string   `json:"source_locator"`
	Aliases         []string `json:"aliases,omitempty"`
}

func (w *KnowledgeIngestionWorker) process(ctx context.Context, job *models.AIKnowledgeIngestionJob) error {
	var document models.AIKnowledgeDocument
	if err := w.db.WithContext(ctx).First(&document, job.DocumentID).Error; err != nil {
		return err
	}
	chunks := splitKnowledgeDocument(document.Content, 700, 80)
	if len(chunks) == 0 {
		return errors.New("knowledge_document_empty")
	}
	prepared := make([]preparedKnowledgeChunk, len(chunks))
	texts := make([]string, len(chunks))
	for index, chunk := range chunks {
		embeddingText := buildKnowledgeEmbeddingText(document, chunk)
		analysis, err := w.rag.Analyze(ctx, embeddingText)
		if err != nil {
			return fmt.Errorf("analyze_chunk: %w", err)
		}
		metadata, err := json.Marshal(knowledgeChunkMetadata{
			ChunkingVersion: structuredChunkingVersion,
			DocumentTitle:   document.Title, DocumentType: document.DocumentType, Department: document.Department,
			SectionTitle: chunk.SectionTitle, SectionPath: chunk.SectionPath,
			SourceLocator: chunk.SourceLocator, Aliases: chunk.Aliases,
		})
		if err != nil {
			return fmt.Errorf("marshal_chunk_metadata: %w", err)
		}
		hash := sha256.Sum256([]byte(chunk.Content))
		prepared[index] = preparedKnowledgeChunk{
			index: index, content: chunk.Content, contentHash: hex.EncodeToString(hash[:]),
			searchTokens: analysis.SearchString, sectionTitle: chunk.SectionTitle,
			sourceLocator: chunk.SourceLocator, metadata: metadata,
		}
		texts[index] = embeddingText
	}
	for start := 0; start < len(texts); start += 32 {
		end := start + 32
		if end > len(texts) {
			end = len(texts)
		}
		embeddings, version, err := w.rag.EmbedBatch(ctx, texts[start:end])
		if err != nil {
			return fmt.Errorf("embed_chunks: %w", err)
		}
		if version != w.modelVersion {
			return fmt.Errorf("embedding_model_version_mismatch")
		}
		for offset, embedding := range embeddings {
			prepared[start+offset].embedding = embedding
		}
	}

	return w.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := ensureActiveEmbeddingModel(tx, w.modelVersion); err != nil {
			return err
		}
		var current models.AIKnowledgeDocument
		query := tx.Select("id", "title", "document_type", "department", "content_hash", "status").Where("id = ?", document.ID)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&current).Error; err != nil {
			return err
		}
		if current.ContentHash != document.ContentHash || current.Title != document.Title ||
			current.DocumentType != document.DocumentType || current.Department != document.Department {
			return errors.New("knowledge_document_changed_during_ingestion")
		}
		if job.RestoreStatus == models.KnowledgeStatusPublished && current.Status != models.KnowledgeStatusPublished {
			return errors.New("published_knowledge_document_status_changed")
		}
		if job.RestoreStatus != models.KnowledgeStatusPublished && current.Status != models.KnowledgeStatusIndexing {
			return errors.New("knowledge_document_status_changed_during_ingestion")
		}
		// 删除和写入必须处于同一事务；任何新块写入失败都会回滚并恢复旧索引。
		if err := tx.Where("document_id = ?", document.ID).Delete(&models.AIKnowledgeChunk{}).Error; err != nil {
			return err
		}
		for _, chunk := range prepared {
			if tx.Dialector.Name() == "postgres" {
				err := tx.Exec(`INSERT INTO ai_knowledge_chunks
					(document_id, chunk_index, content, content_hash, search_tokens, embedding,
					 section_title, source_locator, embedding_model_version, metadata, created_at)
					VALUES (?, ?, ?, ?, ?, ?::vector, ?, ?, ?, ?::jsonb, ?)`,
					document.ID, chunk.index, chunk.content, chunk.contentHash, chunk.searchTokens,
					formatEmbedding(chunk.embedding), chunk.sectionTitle, chunk.sourceLocator,
					w.modelVersion, string(chunk.metadata), time.Now()).Error
				if err != nil {
					return err
				}
			} else {
				row := models.AIKnowledgeChunk{
					DocumentID: document.ID, ChunkIndex: chunk.index, Content: chunk.content,
					ContentHash: chunk.contentHash, SearchTokens: chunk.searchTokens,
					Embedding: formatEmbedding(chunk.embedding), SectionTitle: chunk.sectionTitle,
					SourceLocator: chunk.sourceLocator, EmbeddingModelVersion: w.modelVersion,
					Metadata: chunk.metadata,
				}
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
			}
		}
		inspection, _ := json.Marshal(map[string]interface{}{
			"bytes": len(document.Content), "runes": utf8.RuneCountInString(document.Content),
			"content_hash": document.ContentHash, "unresolved_items": []string{},
			"chunk_count": len(prepared), "chunking_version": structuredChunkingVersion,
			"embedding_model_version": w.modelVersion,
		})
		now := time.Now()
		restoreStatus := job.RestoreStatus
		if restoreStatus != models.KnowledgeStatusPublished {
			restoreStatus = models.KnowledgeStatusInspected
		}
		if err := tx.Model(&models.AIKnowledgeDocument{}).Where("id = ?", document.ID).Updates(map[string]interface{}{
			"status": restoreStatus, "inspection": string(inspection),
			"reindex_requested_at": nil, "updated_at": now,
		}).Error; err != nil {
			return err
		}
		return tx.Model(&models.AIKnowledgeIngestionJob{}).Where("id = ?", job.ID).Updates(map[string]interface{}{
			"status": knowledgeJobCompleted, "completed_at": now, "updated_at": now,
		}).Error
	})
}

func (w *KnowledgeIngestionWorker) failJob(job models.AIKnowledgeIngestionJob, processErr error) {
	status := knowledgeJobFailed
	notBefore := time.Now()
	documentStatus := models.KnowledgeStatusFailed
	if job.RestoreStatus == models.KnowledgeStatusPublished {
		documentStatus = models.KnowledgeStatusPublished
	}
	if job.Attempt < 3 {
		status = knowledgeJobQueued
		notBefore = notBefore.Add(time.Duration(job.Attempt*job.Attempt) * time.Minute)
		if job.RestoreStatus != models.KnowledgeStatusPublished {
			documentStatus = models.KnowledgeStatusNeedsReview
		}
	}
	detail := processErr.Error()
	if len(detail) > 500 {
		detail = detail[:500]
	}
	_ = w.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Model(&models.AIKnowledgeIngestionJob{}).Where("id = ?", job.ID).Updates(map[string]interface{}{
			"status": status, "not_before": notBefore, "error_code": "knowledge_ingestion_failed",
			"error_detail": detail, "updated_at": time.Now(),
		}).Error; err != nil {
			return err
		}
		return tx.Model(&models.AIKnowledgeDocument{}).Where("id = ?", job.DocumentID).Update("status", documentStatus).Error
	})
}

func ensureActiveEmbeddingModel(tx *gorm.DB, version string) error {
	var active models.AIEmbeddingModelRegistry
	err := tx.Where("active = ?", true).First(&active).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		now := time.Now()
		return tx.Create(&models.AIEmbeddingModelRegistry{
			Version: version, ModelName: version, Dimensions: 1536, Active: true, ActivatedAt: &now,
		}).Error
	}
	if err != nil {
		return err
	}
	if active.Version != version || active.Dimensions != 1536 {
		return errors.New("active_embedding_model_mismatch")
	}
	return nil
}

func buildKnowledgeEmbeddingText(document models.AIKnowledgeDocument, chunk knowledgeTextChunk) string {
	sectionPath := strings.Join(chunk.SectionPath, " > ")
	if sectionPath == "" {
		sectionPath = chunk.SectionTitle
	}
	parts := []string{
		document.Title,
		document.DocumentType,
		document.Department,
		sectionPath,
		strings.Join(chunk.Aliases, " "),
		chunk.Content,
	}
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if part = strings.TrimSpace(part); part != "" {
			result = append(result, part)
		}
	}
	return strings.Join(result, "\n")
}

func formatEmbedding(values []float32) string {
	parts := make([]string, len(values))
	for index, value := range values {
		parts[index] = fmt.Sprintf("%.7f", value)
	}
	return "[" + strings.Join(parts, ",") + "]"
}
