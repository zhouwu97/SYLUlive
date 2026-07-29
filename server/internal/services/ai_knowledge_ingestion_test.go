package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
)

const (
	testKnowledgeEmbeddingModelName  = "test-multilingual-model"
	testKnowledgeEmbeddingModel      = "test-multilingual-model-384-v1"
	testKnowledgeEmbeddingDimensions = 384
)

func TestKnowledgeIngestionUsesPythonChunksAndRealEmbeddingDimensions(t *testing.T) {
	db := openKnowledgeIngestionTestDB(t)
	rag, recorder := newKnowledgeRAGTestClient(t, testKnowledgeEmbeddingDimensions)
	document := createKnowledgeDocument(t, db, models.KnowledgeStatusIndexing,
		"## 办理规则\n\n检索别名：挂科、补考\n\n课程首次考核不合格可参加二次考试。")
	job := models.AIKnowledgeIngestionJob{ID: "job-langchain-document", DocumentID: document.ID, RestoreStatus: models.KnowledgeStatusInspected}
	worker := NewKnowledgeIngestionWorker(db, rag, testKnowledgeEmbeddingModel)
	require.NoError(t, worker.process(context.Background(), &job))

	chunkRequests, analyzed, embedded := recorder.snapshot()
	require.Len(t, chunkRequests, 1)
	require.Equal(t, document.ID, chunkRequests[0].DocumentID)
	require.Equal(t, document.DocumentType, chunkRequests[0].DocumentType)
	require.Equal(t, analyzed, embedded)
	require.NotEmpty(t, embedded)
	for _, expected := range []string{document.Title, document.DocumentType, document.Department, "办理规则", "挂科 补考", "课程首次考核不合格"} {
		require.Contains(t, embedded[0], expected)
	}

	var stored models.AIKnowledgeChunk
	require.NoError(t, db.Where("document_id = ?", document.ID).First(&stored).Error)
	require.Equal(t, "课程首次考核不合格可参加二次考试。", stored.Content)
	require.NotContains(t, stored.Content, document.Title)
	require.Empty(t, stored.Embedding, "384 维向量不得写入兼容 vector(1536) 列")
	require.Equal(t, "办理规则", stored.SourceLocator)
	var metadata map[string]interface{}
	require.NoError(t, json.Unmarshal(stored.Metadata, &metadata))
	for _, key := range []string{"document_id", "section_title", "section_path", "source_locator", "document_type", "department", "version_status", "effective_from"} {
		require.Contains(t, metadata, key)
	}

	var shadow models.AIKnowledgeChunkEmbedding
	require.NoError(t, db.Where("chunk_id = ?", stored.ID).First(&shadow).Error)
	require.Equal(t, testKnowledgeEmbeddingModel, shadow.ModelVersion)
	require.Equal(t, testKnowledgeEmbeddingDimensions, shadow.Dimensions)
	require.Len(t, strings.Split(strings.Trim(shadow.Embedding, "[]"), ","), testKnowledgeEmbeddingDimensions)

	var inspection map[string]interface{}
	var refreshed models.AIKnowledgeDocument
	require.NoError(t, db.First(&refreshed, document.ID).Error)
	require.NoError(t, json.Unmarshal([]byte(refreshed.Inspection), &inspection))
	require.Equal(t, "langchain-chinese-policy-v1", inspection["chunking_version"])
	require.Equal(t, float64(testKnowledgeEmbeddingDimensions), inspection["embedding_dimensions"])
}

func TestPublishedKnowledgeReindexFailureKeepsOldIndexAndShadowVector(t *testing.T) {
	db := openKnowledgeIngestionTestDB(t)
	rag, _ := newKnowledgeRAGTestClient(t, testKnowledgeEmbeddingDimensions)
	document := createKnowledgeDocument(t, db, models.KnowledgeStatusPublished, "## 新规则\n\n新索引正文。")
	oldChunk := models.AIKnowledgeChunk{
		DocumentID: document.ID, ChunkIndex: 0, Content: "仍可检索的旧索引正文。",
		ContentHash: "old-hash", SearchTokens: "旧索引", SectionTitle: "旧规则",
		SourceLocator: "旧规则第一条", Metadata: []byte(`{"chunking_version":"legacy"}`),
		EmbeddingModelVersion: testKnowledgeEmbeddingModel,
	}
	require.NoError(t, db.Create(&oldChunk).Error)
	oldShadow := models.AIKnowledgeChunkEmbedding{
		ChunkID: oldChunk.ID, ModelVersion: testKnowledgeEmbeddingModel,
		Dimensions: testKnowledgeEmbeddingDimensions, Embedding: "[0]",
	}
	require.NoError(t, db.Create(&oldShadow).Error)
	_, err := EnqueueKnowledgeIngestion(db, document.ID, models.KnowledgeStatusPublished)
	require.NoError(t, err)
	require.NoError(t, db.Exec(`CREATE TRIGGER fail_new_shadow_embedding
		BEFORE INSERT ON ai_knowledge_chunk_embeddings
		BEGIN SELECT RAISE(ABORT, '模拟影子向量写入失败'); END`).Error)

	worker := NewKnowledgeIngestionWorker(db, rag, testKnowledgeEmbeddingModel)
	processed, processErr := worker.ProcessNext(context.Background())
	require.True(t, processed)
	require.Error(t, processErr)

	var refreshedDocument models.AIKnowledgeDocument
	require.NoError(t, db.First(&refreshedDocument, document.ID).Error)
	require.Equal(t, models.KnowledgeStatusPublished, refreshedDocument.Status)
	var chunks []models.AIKnowledgeChunk
	require.NoError(t, db.Where("document_id = ?", document.ID).Find(&chunks).Error)
	require.Len(t, chunks, 1)
	require.Equal(t, oldChunk.ID, chunks[0].ID)
	require.Equal(t, oldChunk.Content, chunks[0].Content)
	var shadows []models.AIKnowledgeChunkEmbedding
	require.NoError(t, db.Where("chunk_id = ?", oldChunk.ID).Find(&shadows).Error)
	require.Len(t, shadows, 1)
	require.Equal(t, oldShadow.ID, shadows[0].ID)
	var queued models.AIKnowledgeIngestionJob
	require.NoError(t, db.Where("document_id = ?", document.ID).First(&queued).Error)
	require.Equal(t, knowledgeJobQueued, queued.Status)
}

func TestEmbeddingDimensionMismatchFailsBeforeReplacingPublishedIndex(t *testing.T) {
	db := openKnowledgeIngestionTestDB(t)
	rag, _ := newKnowledgeRAGTestClient(t, 768)
	document := createKnowledgeDocument(t, db, models.KnowledgeStatusPublished, "发布正文")
	oldChunk := models.AIKnowledgeChunk{
		DocumentID: document.ID, ChunkIndex: 0, Content: "旧索引", ContentHash: "old",
		SourceLocator: "正文", Metadata: []byte(`{}`), EmbeddingModelVersion: testKnowledgeEmbeddingModel,
	}
	require.NoError(t, db.Create(&oldChunk).Error)
	job := models.AIKnowledgeIngestionJob{ID: "dimension-mismatch", DocumentID: document.ID, RestoreStatus: models.KnowledgeStatusPublished}

	worker := NewKnowledgeIngestionWorker(db, rag, testKnowledgeEmbeddingModel)
	err := worker.process(context.Background(), &job)
	require.ErrorContains(t, err, "embedding_model_registry_mismatch")

	var stored models.AIKnowledgeChunk
	require.NoError(t, db.First(&stored, oldChunk.ID).Error)
	require.Equal(t, "旧索引", stored.Content)
}

func TestEnqueueKnowledgeIngestionIsIdempotentWhilePending(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:knowledge-jobs?mode=memory&cache=shared"), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.AIKnowledgeIngestionJob{}))
	first, err := EnqueueKnowledgeIngestion(db, 9)
	require.NoError(t, err)
	second, err := EnqueueKnowledgeIngestion(db, 9)
	require.NoError(t, err)
	require.Equal(t, first.ID, second.ID)
}

type knowledgeRAGRecorder struct {
	mu            sync.Mutex
	chunkRequests []ai.KnowledgeChunkRequest
	analyzed      []string
	embedded      []string
}

func (r *knowledgeRAGRecorder) snapshot() ([]ai.KnowledgeChunkRequest, []string, []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]ai.KnowledgeChunkRequest(nil), r.chunkRequests...), append([]string(nil), r.analyzed...), append([]string(nil), r.embedded...)
}

func newKnowledgeRAGTestClient(t *testing.T, dimensions int) (*ai.RAGClient, *knowledgeRAGRecorder) {
	t.Helper()
	recorder := &knowledgeRAGRecorder{}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		defer request.Body.Close()
		response.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/internal/rag/knowledge/chunk":
			var payload ai.KnowledgeChunkRequest
			require.NoError(t, json.NewDecoder(request.Body).Decode(&payload))
			recorder.mu.Lock()
			recorder.chunkRequests = append(recorder.chunkRequests, payload)
			recorder.mu.Unlock()
			content := strings.TrimSpace(payload.Content)
			if strings.Contains(content, "课程首次考核") {
				content = "课程首次考核不合格可参加二次考试。"
			}
			embeddingText := strings.Join([]string{payload.Title, payload.DocumentType, payload.Department, "办理规则", "挂科 补考", content}, "\n")
			hash := sha256.Sum256([]byte(content))
			metadata := map[string]interface{}{
				"document_id": payload.DocumentID, "section_title": "办理规则",
				"section_path": []string{"办理规则"}, "source_locator": "办理规则",
				"document_type": payload.DocumentType, "department": payload.Department,
				"version_status": payload.VersionStatus, "effective_from": payload.EffectiveFrom, "effective_to": payload.EffectiveTo,
				"chunking_version": "langchain-chinese-policy-v1", "aliases": []string{"挂科", "补考"},
			}
			require.NoError(t, json.NewEncoder(response).Encode(map[string]interface{}{
				"document_id": payload.DocumentID, "chunking_version": "langchain-chinese-policy-v1",
				"chunks": []map[string]interface{}{{
					"index": 0, "content": content, "content_hash": hex.EncodeToString(hash[:]),
					"embedding_text": embeddingText, "section_title": "办理规则",
					"source_locator": "办理规则", "metadata": metadata,
				}},
			}))
		case "/internal/rag/analyze":
			var payload struct {
				Text string `json:"text"`
			}
			require.NoError(t, json.NewDecoder(request.Body).Decode(&payload))
			recorder.mu.Lock()
			recorder.analyzed = append(recorder.analyzed, payload.Text)
			recorder.mu.Unlock()
			require.NoError(t, json.NewEncoder(response).Encode(map[string]interface{}{
				"tokens": []string{"规则"}, "search_string": payload.Text, "model_version": "test-analyzer-v1",
			}))
		case "/internal/rag/embed-batch":
			var payload struct {
				Texts []string `json:"texts"`
			}
			require.NoError(t, json.NewDecoder(request.Body).Decode(&payload))
			recorder.mu.Lock()
			recorder.embedded = append(recorder.embedded, payload.Texts...)
			recorder.mu.Unlock()
			embeddings := make([][]float32, len(payload.Texts))
			for index := range embeddings {
				embeddings[index] = make([]float32, dimensions)
			}
			require.NoError(t, json.NewEncoder(response).Encode(map[string]interface{}{
				"embeddings": embeddings, "model_name": testKnowledgeEmbeddingModelName,
				"model_version": testKnowledgeEmbeddingModel, "dimensions": dimensions,
			}))
		default:
			http.NotFound(response, request)
		}
	}))
	t.Cleanup(server.Close)
	rag, err := ai.NewRAGClient(server.URL, "test-service-token", server.Client())
	require.NoError(t, err)
	return rag, recorder
}

func openKnowledgeIngestionTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s-%d?mode=memory&cache=shared&_foreign_keys=1", strings.ReplaceAll(t.Name(), "/", "_"), time.Now().UnixNano())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{}, &models.AIKnowledgeChunkEmbedding{},
		&models.AIKnowledgeIngestionJob{}, &models.AIEmbeddingModelRegistry{},
	))
	now := time.Now()
	require.NoError(t, db.Create(&models.AIEmbeddingModelRegistry{
		Version: testKnowledgeEmbeddingModel, ModelName: testKnowledgeEmbeddingModelName,
		Dimensions: testKnowledgeEmbeddingDimensions, Active: true, ActivatedAt: &now,
	}).Error)
	return db
}

func createKnowledgeDocument(t *testing.T, db *gorm.DB, status, content string) models.AIKnowledgeDocument {
	t.Helper()
	hash := sha256.Sum256([]byte(content))
	document := models.AIKnowledgeDocument{
		Title: "本科生课程考核办法", SourceType: "text", DocumentType: "school_exam_policy",
		Department: "教务处", Content: content, ContentHash: hex.EncodeToString(hash[:]), Status: status, CreatedBy: 1,
	}
	require.NoError(t, db.Create(&document).Error)
	return document
}
