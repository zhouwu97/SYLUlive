package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

const testKnowledgeEmbeddingModel = "test-embedding-1536-v1"

func TestSplitKnowledgeDocumentCreatesBoundedOverlappingChunks(t *testing.T) {
	content := "第一章：\n" + strings.Repeat("校园政策内容。", 120) + "\n第二章：\n" + strings.Repeat("办理流程说明。", 120)
	chunks := splitKnowledgeDocument(content, 180, 20)
	require.Greater(t, len(chunks), 2)
	for _, chunk := range chunks {
		require.LessOrEqual(t, len([]rune(chunk.Content)), 180)
		require.NotEmpty(t, chunk.Content)
	}
}

func TestSplitKnowledgeDocumentPreservesPolicyStructures(t *testing.T) {
	t.Run("长条款不按软边界截断", func(t *testing.T) {
		article := "第九条 " + strings.Repeat("完整条款内容", 25)
		chunks := splitKnowledgeDocument("第一章 总则\n"+article+"\n第十条 后续条款。", 120, 20)
		require.Len(t, chunks, 2)
		require.Contains(t, chunks[0].Content, article)
		require.NotContains(t, chunks[0].Content, "第十条")
		require.Equal(t, "第九条", chunks[0].SourceLocator)
		require.Equal(t, []string{"第一章 总则", "第九条"}, chunks[0].SectionPath)
	})

	t.Run("短条款各自保持完整", func(t *testing.T) {
		chunks := splitKnowledgeDocument("第一章 总则\n第一条 第一条正文。\n第二条 第二条正文。", 700, 80)
		require.Len(t, chunks, 2)
		require.Contains(t, chunks[0].Content, "第一条正文")
		require.NotContains(t, chunks[0].Content, "第二条正文")
		require.Equal(t, "第二条", chunks[1].SourceLocator)
	})

	t.Run("表格标题和表格整体保留", func(t *testing.T) {
		content := "## 成绩奖励\n\n表3 国家级竞赛奖励倍率\n| 奖项 | 倍率 |\n|---|---|\n| 一等奖 | 1.8 |\n| 二等奖 | 1.6 |"
		chunks := splitKnowledgeDocument(content, 80, 10)
		require.Len(t, chunks, 1)
		require.Contains(t, chunks[0].Content, "表3 国家级竞赛奖励倍率")
		require.Contains(t, chunks[0].Content, "| 二等奖 | 1.6 |")
		require.Equal(t, "表3 国家级竞赛奖励倍率", chunks[0].SourceLocator)
	})

	t.Run("无标题正文使用可读定位", func(t *testing.T) {
		chunks := splitKnowledgeDocument("第一段没有标题。\n\n第二段继续说明。", 700, 80)
		require.Len(t, chunks, 1)
		require.Equal(t, "正文", chunks[0].SourceLocator)
		require.Empty(t, chunks[0].SectionTitle)
	})

	t.Run("中文部分和数字项生成层级定位", func(t *testing.T) {
		content := "四、重修报名\n1. 每学期不得超过三门。\n2. 逾期未缴费不能参加。"
		chunks := splitKnowledgeDocument(content, 700, 80)
		require.Len(t, chunks, 2)
		require.Equal(t, "第四部分第1项", chunks[0].SourceLocator)
		require.Equal(t, "第四部分第2项", chunks[1].SourceLocator)
		require.Equal(t, []string{"四、重修报名"}, chunks[1].SectionPath)
	})

	t.Run("括号中文序号在非条款下独立定位", func(t *testing.T) {
		content := "关于课程重修\n（一）课程不合格可以重修。\n（二）实践环节不合格可以重修。"
		chunks := splitKnowledgeDocument(content, 700, 80)
		require.Len(t, chunks, 2)
		require.Equal(t, "关于课程重修第一项", chunks[0].SourceLocator)
		require.Equal(t, "关于课程重修第二项", chunks[1].SourceLocator)
		require.NotContains(t, chunks[0].Content, "实践环节")
	})

	t.Run("FAQ问题和回答保持同块", func(t *testing.T) {
		content := "## 常见问题\n\nQ：补考成绩怎么算？\n\nA：历史规则按D/F记载。"
		chunks := splitKnowledgeDocument(content, 700, 80)
		require.Len(t, chunks, 1)
		require.Contains(t, chunks[0].Content, "Q：补考成绩怎么算？")
		require.Contains(t, chunks[0].Content, "A：历史规则按D/F记载。")
		require.Equal(t, "Q：补考成绩怎么算？", chunks[0].SourceLocator)
	})

	t.Run("超长内容只重叠完整句子", func(t *testing.T) {
		first := strings.Repeat("甲", 45) + "。"
		second := strings.Repeat("乙", 45) + "。"
		third := strings.Repeat("丙", 45) + "。"
		fourth := strings.Repeat("丁", 45) + "。"
		chunks := splitKnowledgeDocument("第九条 "+first+second+third+fourth+"\n\n检索别名：超长条款", 80, 50)
		require.Greater(t, len(chunks), 1)
		require.Contains(t, chunks[1].Content, first)
		require.Contains(t, chunks[1].Content, second)
		require.NotContains(t, chunks[1].Content, strings.Repeat("甲", 20)+"乙")
		for _, chunk := range chunks {
			require.Equal(t, []string{"超长条款"}, chunk.Aliases)
		}
	})
}

func TestKnowledgeEmbeddingTextIncludesMetadataWithoutChangingContent(t *testing.T) {
	document := models.AIKnowledgeDocument{
		Title: "课程考核办法", DocumentType: "school_exam_policy", Department: "教务处",
	}
	chunk := knowledgeTextChunk{
		Content: "二考成绩按历史规则记载。", SectionTitle: "第三章 成绩记载",
		SectionPath: []string{"课程考核办法", "第三章 成绩记载"},
		Aliases:     []string{"补考", "二考"}, SourceLocator: "第九条",
	}
	text := buildKnowledgeEmbeddingText(document, chunk)
	for _, expected := range []string{"课程考核办法", "school_exam_policy", "教务处", "第三章 成绩记载", "补考 二考", chunk.Content} {
		require.Contains(t, text, expected)
	}
	require.Equal(t, "二考成绩按历史规则记载。", chunk.Content)
}

func TestKnowledgeIngestionUsesSameStructuredTextForAnalyzeAndEmbed(t *testing.T) {
	db := openKnowledgeIngestionTestDB(t)
	rag, recorder := newKnowledgeRAGTestClient(t)
	document := createKnowledgeDocument(t, db, models.KnowledgeStatusIndexing,
		"## 办理规则\n\n检索别名：挂科、补考\n\n课程首次考核不合格可参加二次考试。")
	job := models.AIKnowledgeIngestionJob{ID: "job-structured-text", DocumentID: document.ID, RestoreStatus: models.KnowledgeStatusInspected}
	worker := NewKnowledgeIngestionWorker(db, rag, testKnowledgeEmbeddingModel)
	require.NoError(t, worker.process(context.Background(), &job))

	analyzed, embedded := recorder.snapshot()
	require.NotEmpty(t, analyzed)
	require.Equal(t, analyzed, embedded)
	for _, text := range analyzed {
		for _, expected := range []string{document.Title, document.DocumentType, document.Department, "办理规则", "挂科 补考", "课程首次考核不合格"} {
			require.Contains(t, text, expected)
		}
	}

	var stored models.AIKnowledgeChunk
	require.NoError(t, db.Where("document_id = ?", document.ID).First(&stored).Error)
	require.NotContains(t, stored.Content, document.Title)
	require.NotContains(t, stored.Content, document.DocumentType)
	require.NotContains(t, stored.Content, document.Department)
	var metadata knowledgeChunkMetadata
	require.NoError(t, json.Unmarshal(stored.Metadata, &metadata))
	require.Equal(t, structuredChunkingVersion, metadata.ChunkingVersion)
	require.Equal(t, "办理规则", metadata.SectionTitle)
	require.Equal(t, []string{"挂科", "补考"}, metadata.Aliases)
	require.NotEqual(t, "chunk:1", stored.SourceLocator)
}

func TestPublishedKnowledgeReindexFailureKeepsOldIndex(t *testing.T) {
	db := openKnowledgeIngestionTestDB(t)
	rag, _ := newKnowledgeRAGTestClient(t)
	document := createKnowledgeDocument(t, db, models.KnowledgeStatusPublished, "## 新规则\n\n新索引正文。")
	oldChunk := models.AIKnowledgeChunk{
		DocumentID: document.ID, ChunkIndex: 0, Content: "仍可检索的旧索引正文。",
		ContentHash: "old-hash", SearchTokens: "旧索引", Embedding: "[0]",
		SectionTitle: "旧规则", SourceLocator: "旧规则第一条", Metadata: []byte(`{"chunking_version":"legacy"}`),
		EmbeddingModelVersion: testKnowledgeEmbeddingModel,
	}
	require.NoError(t, db.Create(&oldChunk).Error)
	_, err := EnqueueKnowledgeIngestion(db, document.ID, models.KnowledgeStatusPublished)
	require.NoError(t, err)
	require.NoError(t, db.Exec(`CREATE TRIGGER fail_new_knowledge_chunk
		BEFORE INSERT ON ai_knowledge_chunks
		WHEN NEW.content LIKE '%新索引正文%'
		BEGIN SELECT RAISE(ABORT, '模拟新索引写入失败'); END`).Error)

	worker := NewKnowledgeIngestionWorker(db, rag, testKnowledgeEmbeddingModel)
	processed, processErr := worker.ProcessNext(context.Background())
	require.True(t, processed)
	require.Error(t, processErr)

	var refreshedDocument models.AIKnowledgeDocument
	require.NoError(t, db.First(&refreshedDocument, document.ID).Error)
	require.Equal(t, models.KnowledgeStatusPublished, refreshedDocument.Status)
	var chunks []models.AIKnowledgeChunk
	require.NoError(t, db.Where("document_id = ?", document.ID).Order("chunk_index").Find(&chunks).Error)
	require.Len(t, chunks, 1)
	require.Equal(t, oldChunk.ID, chunks[0].ID)
	require.Equal(t, oldChunk.Content, chunks[0].Content)
	require.Equal(t, oldChunk.SourceLocator, chunks[0].SourceLocator)
	var queued models.AIKnowledgeIngestionJob
	require.NoError(t, db.Where("document_id = ?", document.ID).First(&queued).Error)
	require.Equal(t, knowledgeJobQueued, queued.Status)
}

func TestV06RuleCardStructuredChunkingComparison(t *testing.T) {
	path := filepath.Join("..", "..", "..", "knowledge-base", "sylu-academic-policy", "v0.6", "documents", "sylu-second-exam-retake-policy-card-v06.md")
	content, err := os.ReadFile(path)
	require.NoError(t, err)
	legacy := splitKnowledgeDocumentLegacy(string(content), 700, 80)
	structured := splitKnowledgeDocument(string(content), 700, 80)
	require.NotEmpty(t, legacy)
	require.NotEmpty(t, structured)

	keyStatements := []string{
		"二考成绩只记“及格”或“不及格”，等级为D或F，对应绩点为1或0",
		"二考一般安排在开学初，学生自愿参加",
		"未参加二考或二考仍未取得学分者，必须缴费重修",
	}
	legacyComplete := completeStatementCountLegacy(legacy, keyStatements)
	structuredComplete := completeStatementCount(structured, keyStatements)
	readableLocators := 0
	for _, chunk := range structured {
		require.NotEmpty(t, chunk.SourceLocator)
		require.False(t, strings.HasPrefix(chunk.SourceLocator, "chunk:"))
		readableLocators++
	}
	require.Equal(t, len(keyStatements), structuredComplete)
	target := findKnowledgeChunk(structured, "等级为D或F，对应绩点为1或0")
	require.NotNil(t, target)
	require.Contains(t, target.SourceLocator, "第3项")
	legacyTarget := findLegacyKnowledgeChunk(legacy, "等级为D或F，对应绩点为1或0")
	require.NotNil(t, legacyTarget)
	t.Logf("v0.6规则卡对比: 旧分块=%d, 新分块=%d, 关键规则完整=%d/%d -> %d/%d, 可读locator=%d/%d -> %d/%d, D/F规则上下文长度=%d -> %d, locator=%s -> %s",
		len(legacy), len(structured), legacyComplete, len(keyStatements), structuredComplete, len(keyStatements),
		0, len(legacy), readableLocators, len(structured), len([]rune(legacyTarget.content)), len([]rune(target.Content)),
		legacyTarget.locator, target.SourceLocator)
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
	mu       sync.Mutex
	analyzed []string
	embedded []string
}

func (r *knowledgeRAGRecorder) snapshot() ([]string, []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.analyzed...), append([]string(nil), r.embedded...)
}

func newKnowledgeRAGTestClient(t *testing.T) (*ai.RAGClient, *knowledgeRAGRecorder) {
	t.Helper()
	recorder := &knowledgeRAGRecorder{}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		defer request.Body.Close()
		response.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
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
				embeddings[index] = make([]float32, 1536)
			}
			require.NoError(t, json.NewEncoder(response).Encode(map[string]interface{}{
				"embeddings": embeddings, "model_version": testKnowledgeEmbeddingModel, "dimensions": 1536,
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
		&models.AIKnowledgeDocument{}, &models.AIKnowledgeChunk{},
		&models.AIKnowledgeIngestionJob{}, &models.AIEmbeddingModelRegistry{},
	))
	now := time.Now()
	require.NoError(t, db.Create(&models.AIEmbeddingModelRegistry{
		Version: testKnowledgeEmbeddingModel, ModelName: testKnowledgeEmbeddingModel,
		Dimensions: 1536, Active: true, ActivatedAt: &now,
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

type legacyKnowledgeChunk struct {
	content string
	locator string
}

func splitKnowledgeDocumentLegacy(content string, maxRunes, overlapRunes int) []legacyKnowledgeChunk {
	content = strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", "\n")
	paragraphs := strings.Split(content, "\n")
	chunks := make([]legacyKnowledgeChunk, 0)
	buffer := make([]rune, 0, maxRunes)
	flush := func() {
		text := strings.TrimSpace(string(buffer))
		if text != "" {
			chunks = append(chunks, legacyKnowledgeChunk{content: text, locator: fmt.Sprintf("chunk:%d", len(chunks)+1)})
		}
		if len(buffer) > overlapRunes {
			buffer = append([]rune(nil), buffer[len(buffer)-overlapRunes:]...)
		} else {
			buffer = buffer[:0]
		}
	}
	for _, paragraph := range paragraphs {
		paragraphRunes := []rune(strings.TrimSpace(paragraph))
		if len(paragraphRunes) == 0 {
			continue
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
		chunks = append(chunks, legacyKnowledgeChunk{content: strings.TrimSpace(string(buffer)), locator: fmt.Sprintf("chunk:%d", len(chunks)+1)})
	}
	return chunks
}

func completeStatementCountLegacy(chunks []legacyKnowledgeChunk, statements []string) int {
	count := 0
	for _, statement := range statements {
		for _, chunk := range chunks {
			if strings.Contains(chunk.content, statement) {
				count++
				break
			}
		}
	}
	return count
}

func completeStatementCount(chunks []knowledgeTextChunk, statements []string) int {
	count := 0
	for _, statement := range statements {
		if findKnowledgeChunk(chunks, statement) != nil {
			count++
		}
	}
	return count
}

func findKnowledgeChunk(chunks []knowledgeTextChunk, text string) *knowledgeTextChunk {
	for index := range chunks {
		if strings.Contains(chunks[index].Content, text) {
			return &chunks[index]
		}
	}
	return nil
}

func findLegacyKnowledgeChunk(chunks []legacyKnowledgeChunk, text string) *legacyKnowledgeChunk {
	for index := range chunks {
		if strings.Contains(chunks[index].content, text) {
			return &chunks[index]
		}
	}
	return nil
}
