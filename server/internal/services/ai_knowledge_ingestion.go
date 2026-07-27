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
	embedding     []float32
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
		// 只把正文送进 Analyze/Embed 时，《课程重修管理办法》里写“首次考核不合格”的段落
		// 在向量空间里无法与重修文件建立联系。标题、类型、部门和章节必须一起编码。
		indexedText := knowledgeChunkIndexText(document, chunk)
		analysis, err := w.rag.Analyze(ctx, indexedText)
		if err != nil {
			return fmt.Errorf("analyze_chunk: %w", err)
		}
		hash := sha256.Sum256([]byte(chunk.Content))
		prepared[index] = preparedKnowledgeChunk{
			index: index, content: chunk.Content, contentHash: hex.EncodeToString(hash[:]),
			searchTokens: analysis.SearchString, sectionTitle: chunk.SectionTitle,
			sourceLocator: knowledgeSourceLocator(chunk.SectionTitle, index),
		}
		texts[index] = indexedText
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
		if err := tx.Where("document_id = ?", document.ID).Delete(&models.AIKnowledgeChunk{}).Error; err != nil {
			return err
		}
		for _, chunk := range prepared {
			if tx.Dialector.Name() == "postgres" {
				err := tx.Exec(`INSERT INTO ai_knowledge_chunks
					(document_id, chunk_index, content, content_hash, search_tokens, embedding,
					 section_title, source_locator, embedding_model_version, metadata, created_at)
					VALUES (?, ?, ?, ?, ?, ?::vector, ?, ?, ?, '{}'::jsonb, ?)`,
					document.ID, chunk.index, chunk.content, chunk.contentHash, chunk.searchTokens,
					formatEmbedding(chunk.embedding), chunk.sectionTitle, chunk.sourceLocator,
					w.modelVersion, time.Now()).Error
				if err != nil {
					return err
				}
			} else {
				row := models.AIKnowledgeChunk{
					DocumentID: document.ID, ChunkIndex: chunk.index, Content: chunk.content,
					ContentHash: chunk.contentHash, SearchTokens: chunk.searchTokens,
					Embedding: formatEmbedding(chunk.embedding), SectionTitle: chunk.sectionTitle,
					SourceLocator: chunk.sourceLocator, EmbeddingModelVersion: w.modelVersion,
				}
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
			}
		}
		inspection, _ := json.Marshal(map[string]interface{}{
			"bytes": len(document.Content), "runes": utf8.RuneCountInString(document.Content),
			"content_hash": document.ContentHash, "unresolved_items": []string{},
			"chunk_count": len(prepared), "embedding_model_version": w.modelVersion,
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

type knowledgeTextChunk struct {
	Content      string
	SectionTitle string
}

// knowledgeChunkIndexText 是同时用于 Analyze 与 Embed 的索引文本。
// 两者必须一致，否则全文分词命中的段落和向量命中的段落会互相错开。
func knowledgeChunkIndexText(document models.AIKnowledgeDocument, chunk knowledgeTextChunk) string {
	parts := make([]string, 0, 5)
	for _, value := range []string{
		document.Title,
		document.DocumentType,
		document.Department,
		chunk.SectionTitle,
	} {
		if value = strings.TrimSpace(value); value != "" {
			parts = append(parts, value)
		}
	}
	parts = append(parts, chunk.Content)
	return strings.Join(parts, "\n")
}

// knowledgeSourceLocator 优先使用章节标题，让来源卡显示“第九条”而不是永远的 chunk:6。
func knowledgeSourceLocator(sectionTitle string, index int) string {
	sectionTitle = strings.TrimSpace(sectionTitle)
	sectionTitle = strings.TrimLeft(sectionTitle, "# ")
	sectionTitle = strings.TrimRight(sectionTitle, "：: ")
	if sectionTitle == "" {
		return fmt.Sprintf("chunk:%d", index+1)
	}
	if runes := []rune(sectionTitle); len(runes) > 40 {
		sectionTitle = string(runes[:40])
	}
	return sectionTitle
}

func splitKnowledgeDocument(content string, maxRunes, overlapRunes int) []knowledgeTextChunk {
	content = strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", "\n")
	paragraphs := strings.Split(content, "\n")
	chunks := make([]knowledgeTextChunk, 0)
	buffer := make([]rune, 0, maxRunes)
	section := ""
	flush := func() {
		text := strings.TrimSpace(string(buffer))
		if text != "" {
			chunks = append(chunks, knowledgeTextChunk{Content: text, SectionTitle: section})
		}
		if len(buffer) > overlapRunes {
			buffer = append([]rune(nil), buffer[len(buffer)-overlapRunes:]...)
		} else {
			buffer = buffer[:0]
		}
	}
	for _, paragraph := range paragraphs {
		paragraph = strings.TrimSpace(paragraph)
		if paragraph == "" {
			continue
		}
		paragraphRunes := []rune(paragraph)
		if len(paragraphRunes) <= 60 && (strings.HasSuffix(paragraph, "：") || strings.HasPrefix(paragraph, "第") || strings.HasPrefix(paragraph, "#")) {
			section = strings.TrimLeft(paragraph, "# ")
		}
		for len(paragraphRunes) > 0 {
			remaining := maxRunes - len(buffer)
			if remaining <= 1 {
				flush()
				remaining = maxRunes - len(buffer)
			}
			count := len(paragraphRunes)
			if count > remaining-1 {
				count = remaining - 1
			}
			if len(buffer) > 0 {
				buffer = append(buffer, '\n')
			}
			buffer = append(buffer, paragraphRunes[:count]...)
			paragraphRunes = paragraphRunes[count:]
			if len(buffer) >= maxRunes-1 {
				flush()
			}
		}
	}
	if strings.TrimSpace(string(buffer)) != "" {
		chunks = append(chunks, knowledgeTextChunk{Content: strings.TrimSpace(string(buffer)), SectionTitle: section})
	}
	return chunks
}

func formatEmbedding(values []float32) string {
	parts := make([]string, len(values))
	for index, value := range values {
		parts[index] = fmt.Sprintf("%.7f", value)
	}
	return "[" + strings.Join(parts, ",") + "]"
}
