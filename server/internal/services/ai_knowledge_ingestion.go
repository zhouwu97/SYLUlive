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

func (w *KnowledgeIngestionWorker) process(ctx context.Context, job *models.AIKnowledgeIngestionJob) error {
	var document models.AIKnowledgeDocument
	if err := w.db.WithContext(ctx).First(&document, job.DocumentID).Error; err != nil {
		return err
	}
	chunkResult, err := w.rag.ChunkKnowledgeDocument(ctx, ai.KnowledgeChunkRequest{
		DocumentID: document.ID, Title: document.Title, Content: document.Content,
		SourceLocator: document.SourceURI, DocumentType: document.DocumentType, Department: document.Department,
		VersionStatus: job.RestoreStatus, EffectiveFrom: document.EffectiveFrom, EffectiveTo: document.EffectiveTo,
		ChunkSize: 700, ChunkOverlap: 80,
	})
	if err != nil {
		return fmt.Errorf("chunk_document: %w", err)
	}
	prepared := make([]preparedKnowledgeChunk, len(chunkResult.Chunks))
	texts := make([]string, len(chunkResult.Chunks))
	for index, chunk := range chunkResult.Chunks {
		hash := sha256.Sum256([]byte(chunk.Content))
		if hex.EncodeToString(hash[:]) != chunk.ContentHash {
			return errors.New("knowledge_chunk_hash_mismatch")
		}
		analysis, err := w.rag.Analyze(ctx, chunk.EmbeddingText)
		if err != nil {
			return fmt.Errorf("analyze_chunk: %w", err)
		}
		prepared[index] = preparedKnowledgeChunk{
			index: index, content: chunk.Content, contentHash: chunk.ContentHash,
			searchTokens: analysis.SearchString, sectionTitle: chunk.SectionTitle,
			sourceLocator: chunk.SourceLocator, metadata: append([]byte(nil), chunk.Metadata...),
		}
		texts[index] = chunk.EmbeddingText
	}
	embeddingModelName := ""
	embeddingDimensions := 0
	for start := 0; start < len(texts); start += 32 {
		end := start + 32
		if end > len(texts) {
			end = len(texts)
		}
		embeddings, modelName, version, dimensions, err := w.rag.EmbedBatch(ctx, texts[start:end])
		if err != nil {
			return fmt.Errorf("embed_chunks: %w", err)
		}
		if version != w.modelVersion {
			return fmt.Errorf("embedding_model_version_mismatch")
		}
		if embeddingDimensions == 0 {
			embeddingModelName, embeddingDimensions = modelName, dimensions
		} else if embeddingModelName != modelName || embeddingDimensions != dimensions {
			return errors.New("embedding_model_contract_changed")
		}
		for offset, embedding := range embeddings {
			prepared[start+offset].embedding = embedding
		}
	}

	return w.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := ensureActiveEmbeddingModel(tx, embeddingModelName, w.modelVersion, embeddingDimensions); err != nil {
			return err
		}
		var current models.AIKnowledgeDocument
		query := tx.Select("id", "title", "source_uri", "document_type", "department", "content_hash", "status", "effective_from", "effective_to").Where("id = ?", document.ID)
		if tx.Dialector.Name() == "postgres" {
			query = query.Clauses(clause.Locking{Strength: "UPDATE"})
		}
		if err := query.First(&current).Error; err != nil {
			return err
		}
		if current.ContentHash != document.ContentHash || current.Title != document.Title ||
			current.SourceURI != document.SourceURI || current.DocumentType != document.DocumentType ||
			current.Department != document.Department || !sameOptionalTime(current.EffectiveFrom, document.EffectiveFrom) ||
			!sameOptionalTime(current.EffectiveTo, document.EffectiveTo) {
			return errors.New("knowledge_document_changed_during_ingestion")
		}
		if job.RestoreStatus == models.KnowledgeStatusPublished && current.Status != models.KnowledgeStatusPublished {
			return errors.New("published_knowledge_document_status_changed")
		}
		if job.RestoreStatus != models.KnowledgeStatusPublished && current.Status != models.KnowledgeStatusIndexing {
			return errors.New("knowledge_document_status_changed_during_ingestion")
		}
		// 删除和写入必须处于同一事务；任何新块写入失败都会回滚并恢复旧索引。
		if err := tx.Exec(`DELETE FROM ai_knowledge_chunk_embeddings
			WHERE chunk_id IN (SELECT id FROM ai_knowledge_chunks WHERE document_id = ?)`, document.ID).Error; err != nil {
			return err
		}
		if err := tx.Where("document_id = ?", document.ID).Delete(&models.AIKnowledgeChunk{}).Error; err != nil {
			return err
		}
		for _, chunk := range prepared {
			var chunkID uint64
			if tx.Dialector.Name() == "postgres" {
				var inserted struct{ ID uint64 }
				var err error
				if embeddingDimensions == 1536 {
					err = tx.Raw(`INSERT INTO ai_knowledge_chunks
						(document_id, chunk_index, content, content_hash, search_tokens, embedding,
						 section_title, source_locator, embedding_model_version, metadata, created_at)
						VALUES (?, ?, ?, ?, ?, ?::vector, ?, ?, ?, ?::jsonb, ?) RETURNING id`,
						document.ID, chunk.index, chunk.content, chunk.contentHash, chunk.searchTokens,
						formatEmbedding(chunk.embedding), chunk.sectionTitle, chunk.sourceLocator,
						w.modelVersion, string(chunk.metadata), time.Now()).Scan(&inserted).Error
				} else {
					err = tx.Raw(`INSERT INTO ai_knowledge_chunks
						(document_id, chunk_index, content, content_hash, search_tokens,
						 section_title, source_locator, embedding_model_version, metadata, created_at)
						VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?) RETURNING id`,
						document.ID, chunk.index, chunk.content, chunk.contentHash, chunk.searchTokens,
						chunk.sectionTitle, chunk.sourceLocator, w.modelVersion, string(chunk.metadata), time.Now()).Scan(&inserted).Error
				}
				if err != nil {
					return err
				}
				chunkID = inserted.ID
				if chunkID == 0 {
					return errors.New("knowledge_chunk_insert_missing_id")
				}
			} else {
				row := models.AIKnowledgeChunk{
					DocumentID: document.ID, ChunkIndex: chunk.index, Content: chunk.content,
					ContentHash: chunk.contentHash, SearchTokens: chunk.searchTokens,
					SectionTitle:  chunk.sectionTitle,
					SourceLocator: chunk.sourceLocator, EmbeddingModelVersion: w.modelVersion,
					Metadata: chunk.metadata,
				}
				if embeddingDimensions == 1536 {
					row.Embedding = formatEmbedding(chunk.embedding)
				}
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
				chunkID = row.ID
			}
			if tx.Dialector.Name() == "postgres" {
				if err := tx.Exec(`INSERT INTO ai_knowledge_chunk_embeddings
					(chunk_id, model_version, dimensions, embedding, created_at)
					VALUES (?, ?, ?, ?::vector, ?)`, chunkID, w.modelVersion, embeddingDimensions,
					formatEmbedding(chunk.embedding), time.Now()).Error; err != nil {
					return err
				}
			} else {
				row := models.AIKnowledgeChunkEmbedding{
					ChunkID: chunkID, ModelVersion: w.modelVersion, Dimensions: embeddingDimensions,
					Embedding: formatEmbedding(chunk.embedding),
				}
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
			}
		}
		inspection, _ := json.Marshal(map[string]interface{}{
			"bytes": len(document.Content), "runes": utf8.RuneCountInString(document.Content),
			"content_hash": document.ContentHash, "unresolved_items": []string{},
			"chunk_count": len(prepared), "chunking_version": chunkResult.ChunkingVersion,
			"embedding_model_name": embeddingModelName, "embedding_model_version": w.modelVersion,
			"embedding_dimensions": embeddingDimensions,
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

func ensureActiveEmbeddingModel(tx *gorm.DB, modelName, version string, dimensions int) error {
	if strings.TrimSpace(modelName) == "" || strings.TrimSpace(version) == "" || dimensions <= 0 || dimensions > 2000 {
		return errors.New("invalid_embedding_model_contract")
	}
	var registered models.AIEmbeddingModelRegistry
	err := tx.Where("version = ?", version).First(&registered).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		var activeCount int64
		if err := tx.Model(&models.AIEmbeddingModelRegistry{}).Where("active = ?", true).Count(&activeCount).Error; err != nil {
			return err
		}
		now := time.Now()
		registered = models.AIEmbeddingModelRegistry{
			Version: version, ModelName: modelName, Dimensions: dimensions,
			Active: activeCount == 0,
		}
		if registered.Active {
			registered.ActivatedAt = &now
		}
		if err := tx.Create(&registered).Error; err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	if registered.ModelName != modelName || registered.Dimensions != dimensions {
		return errors.New("embedding_model_registry_mismatch")
	}
	if !registered.Active {
		return errors.New("active_embedding_model_mismatch")
	}
	return nil
}

func sameOptionalTime(left, right *time.Time) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return left.Equal(*right)
}

func formatEmbedding(values []float32) string {
	parts := make([]string, len(values))
	for index, value := range values {
		parts[index] = fmt.Sprintf("%.7f", value)
	}
	return "[" + strings.Join(parts, ",") + "]"
}
