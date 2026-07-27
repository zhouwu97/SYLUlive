package handlers

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func newKnowledgeTestRouter(t *testing.T, role models.Role, userID uint, ragClients ...*ai.RAGClient) (*gin.Engine, *gorm.DB) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db, err := gorm.Open(sqlite.Open(filepath.Join(t.TempDir(), "knowledge.db")), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	if err := db.AutoMigrate(
		&models.AIKnowledgeDocument{},
		&models.AIKnowledgeChunk{},
		&models.AIKnowledgeChunkEmbedding{},
		&models.AIEmbeddingModelRegistry{},
		&models.AIKnowledgeAuditLog{},
	); err != nil {
		t.Fatal(err)
	}
	handler := NewAIKnowledgeHandler(db, ragClients...)
	router := gin.New()
	group := router.Group("/api/admin/ai/knowledge")
	group.Use(func(c *gin.Context) {
		c.Set("user_id", userID)
		c.Set("role", string(role))
	})
	group.POST("/import", handler.Import)
	group.POST("/release", handler.ReleaseBatch)
	group.POST("/rollback", handler.RollbackBatch)
	group.GET("", handler.List)
	group.GET("/:id", handler.Read)
	group.POST("/:id/inspect", handler.Inspect)
	group.POST("/:id/reindex", handler.Reindex)
	group.POST("/:id/publish", handler.Publish)
	group.POST("/:id/revoke", handler.Revoke)
	group.POST("/:id/supersede", handler.Supersede)
	return router, db
}

func performKnowledgeRequest(router http.Handler, method, path, body string) *httptest.ResponseRecorder {
	response := httptest.NewRecorder()
	request := httptest.NewRequest(method, path, bytes.NewBufferString(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	router.ServeHTTP(response, request)
	return response
}

func TestKnowledgeAdminCanImportInspectAndReindexButCannotPublish(t *testing.T) {
	router, db := newKnowledgeTestRouter(t, models.RoleAdmin, 18)
	response := performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/import", `{"title":"学生手册","source_type":"official","source_uri":"https://example.edu/handbook","document_type":"school_policy","department":"教务处","effective_from":"2026-01-01T00:00:00+08:00","content":"请假应按学校流程办理。"}`)
	if response.Code != http.StatusCreated {
		t.Fatalf("导入失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Document models.AIKnowledgeDocument `json:"document"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	id := strconv.FormatUint(uint64(payload.Document.ID), 10)
	response = performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/"+id+"/inspect", "")
	if response.Code != http.StatusOK {
		t.Fatalf("检查失败: %s", response.Body.String())
	}
	response = performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/"+id+"/reindex", "")
	if response.Code != http.StatusAccepted {
		t.Fatalf("重建索引请求失败: %s", response.Body.String())
	}
	response = performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/"+id+"/publish", "")
	if response.Code != http.StatusForbidden {
		t.Fatalf("普通管理员不应发布: status=%d body=%s", response.Code, response.Body.String())
	}
	var document models.AIKnowledgeDocument
	if err := db.First(&document, payload.Document.ID).Error; err != nil {
		t.Fatal(err)
	}
	if document.Status != models.KnowledgeStatusInspected {
		t.Fatalf("越权发布改变了状态: %s", document.Status)
	}
}

func TestKnowledgePublishUsesAuthenticatedActor(t *testing.T) {
	router, db := newKnowledgeTestRouter(t, models.RoleSuperAdmin, 42)
	document := validInspectedKnowledgeDocument("校规", "正文")
	if err := db.Create(&document).Error; err != nil {
		t.Fatal(err)
	}
	path := "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(document.ID), 10) + "/publish"
	response := performKnowledgeRequest(router, http.MethodPost, path, "")
	if response.Code != http.StatusOK {
		t.Fatalf("超级管理员发布失败: status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&document, document.ID).Error; err != nil {
		t.Fatal(err)
	}
	if document.ReviewedBy != 42 {
		t.Fatalf("审核身份不应来自请求体: %d", document.ReviewedBy)
	}
	var audit models.AIKnowledgeAuditLog
	if err := db.Where("document_id = ? AND action = ?", document.ID, "publish").First(&audit).Error; err != nil {
		t.Fatal(err)
	}
	if audit.ActorUserID != 42 || audit.ActorRole != string(models.RoleSuperAdmin) {
		t.Fatalf("审计身份不可信: %#v", audit)
	}
}

func TestKnowledgePublishRejectsIdentityBody(t *testing.T) {
	router, db := newKnowledgeTestRouter(t, models.RoleSuperAdmin, 42)
	document := validInspectedKnowledgeDocument("校规", "正文")
	if err := db.Create(&document).Error; err != nil {
		t.Fatal(err)
	}
	path := "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(document.ID), 10) + "/publish"
	response := performKnowledgeRequest(router, http.MethodPost, path, `{"reviewer_id":999,"actor_id":999,"role":"user"}`)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("发布动作不应接受身份请求体: status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&document, document.ID).Error; err != nil {
		t.Fatal(err)
	}
	if document.Status != models.KnowledgeStatusInspected || document.ReviewedBy != 0 {
		t.Fatalf("伪造身份请求不应改变文档: %#v", document)
	}
}

func TestKnowledgeImportRejectsActorFields(t *testing.T) {
	router, _ := newKnowledgeTestRouter(t, models.RoleAdmin, 18)
	response := performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/import", `{"title":"校规","source_type":"official","content":"正文","actor_id":999}`)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("导入请求不应接受 actor_id: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestKnowledgeInspectReportsRealUnresolvedItems(t *testing.T) {
	router, db := newKnowledgeTestRouter(t, models.RoleAdmin, 18)
	document := models.AIKnowledgeDocument{
		Title: "待核验抓取内容", SourceType: "crawler", Content: "# 空章节", Status: models.KnowledgeStatusDraft,
		ContentHash: fmt.Sprintf("%x", sha256.Sum256([]byte("# 空章节"))), CreatedBy: 18,
	}
	if err := db.Create(&document).Error; err != nil {
		t.Fatal(err)
	}
	path := "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(document.ID), 10) + "/inspect"
	response := performKnowledgeRequest(router, http.MethodPost, path, "")
	if response.Code != http.StatusOK {
		t.Fatalf("检查失败: status=%d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Document   models.AIKnowledgeDocument         `json:"document"`
		Inspection services.KnowledgeInspectionReport `json:"inspection"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Document.Status != models.KnowledgeStatusNeedsReview || payload.Inspection.BlockingCount == 0 {
		t.Fatalf("待核验问题未阻塞发布: %#v", payload)
	}
	joined := strings.Join(payload.Inspection.UnresolvedItems, "\n")
	for _, code := range []string{"crawler_requires_review", "document_type_missing", "department_missing", "source_locator_missing", "empty_section"} {
		if !strings.Contains(joined, code) {
			t.Fatalf("unresolved_items 缺少 %s: %s", code, joined)
		}
	}
}

func TestKnowledgePublishRejectsDuplicateHash(t *testing.T) {
	router, db := newKnowledgeTestRouter(t, models.RoleSuperAdmin, 42)
	current := validInspectedKnowledgeDocument("当前校规", "相同正文")
	current.Status = models.KnowledgeStatusPublished
	if err := db.Create(&current).Error; err != nil {
		t.Fatal(err)
	}
	duplicate := validInspectedKnowledgeDocument("重复校规", "相同正文")
	if err := db.Create(&duplicate).Error; err != nil {
		t.Fatal(err)
	}
	path := "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(duplicate.ID), 10) + "/publish"
	response := performKnowledgeRequest(router, http.MethodPost, path, "")
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "knowledge_duplicate_content") {
		t.Fatalf("重复内容应被拒绝: status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestKnowledgePublishRejectsIndexVersionDriftWithRAGEnabled(t *testing.T) {
	rag, err := ai.NewRAGClient("http://127.0.0.1", "test-service-token", http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	router, db := newKnowledgeTestRouter(t, models.RoleSuperAdmin, 42, rag)
	document := validInspectedKnowledgeDocument("考试规定", "考试规定正文")
	inspection := services.KnowledgeInspectionReport{
		ChunkCount: 1, ChunkingVersion: "langchain-markdown-v1",
		EmbeddingModelName: "bge-m3", EmbeddingModelVersion: "bge-m3-v1", EmbeddingDimensions: 1024,
	}
	encodedInspection, err := json.Marshal(inspection)
	if err != nil {
		t.Fatal(err)
	}
	document.Inspection = string(encodedInspection)
	if err := db.Create(&document).Error; err != nil {
		t.Fatal(err)
	}
	chunk := models.AIKnowledgeChunk{
		DocumentID: document.ID, ChunkIndex: 0, Content: document.Content, ContentHash: document.ContentHash,
		EmbeddingModelVersion: "bge-m3-v1",
	}
	if err := db.Create(&chunk).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.AIKnowledgeChunkEmbedding{
		ChunkID: chunk.ID, ModelVersion: "bge-m3-v1", Dimensions: 1024, Embedding: "[0]",
	}).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Create(&models.AIEmbeddingModelRegistry{
		Version: "bge-m3-v2", ModelName: "bge-m3", Dimensions: 1024, Active: true,
	}).Error; err != nil {
		t.Fatal(err)
	}

	path := "/api/admin/ai/knowledge/" + strconv.FormatUint(uint64(document.ID), 10) + "/publish"
	response := performKnowledgeRequest(router, http.MethodPost, path, "")
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "knowledge_index_version_drift") {
		t.Fatalf("索引版本漂移应阻止发布: status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&document, document.ID).Error; err != nil {
		t.Fatal(err)
	}
	if document.Status != models.KnowledgeStatusInspected {
		t.Fatalf("拒绝发布后文档状态被改变: %s", document.Status)
	}
}

func TestKnowledgeReleaseBatchRollsBackAllDocumentsWhenOneIsBlocked(t *testing.T) {
	router, db := newKnowledgeTestRouter(t, models.RoleSuperAdmin, 42)
	current := validInspectedKnowledgeDocument("当前考试规定", "当前正文")
	current.DocumentType = "school_exam_policy"
	current.Status = models.KnowledgeStatusPublished
	if err := db.Create(&current).Error; err != nil {
		t.Fatal(err)
	}
	replacement := validInspectedKnowledgeDocument("修订考试规定", "修订正文")
	replacement.DocumentType = current.DocumentType
	if err := db.Create(&replacement).Error; err != nil {
		t.Fatal(err)
	}
	blocked := validInspectedKnowledgeDocument("缺少部门", "另一份正文")
	blocked.DocumentType = "school_other_policy"
	blocked.Department = ""
	if err := db.Create(&blocked).Error; err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`{"version":"v0.6","items":[{"document_id":%d,"supersedes_document_id":%d},{"document_id":%d}]}`,
		replacement.ID, current.ID, blocked.ID)
	response := performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/release", body)
	if response.Code != http.StatusConflict {
		t.Fatalf("含阻塞项的批次应失败: status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&current, current.ID).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.First(&replacement, replacement.ID).Error; err != nil {
		t.Fatal(err)
	}
	if current.Status != models.KnowledgeStatusPublished || replacement.Status != models.KnowledgeStatusInspected {
		t.Fatalf("失败批次发生了部分发布: current=%s replacement=%s", current.Status, replacement.Status)
	}

	body = fmt.Sprintf(`{"version":"v0.6","items":[{"document_id":%d,"supersedes_document_id":%d}]}`, replacement.ID, current.ID)
	response = performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/release", body)
	if response.Code != http.StatusOK {
		t.Fatalf("合法批次发布失败: status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&current, current.ID).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.First(&replacement, replacement.ID).Error; err != nil {
		t.Fatal(err)
	}
	if current.Status != models.KnowledgeStatusSuperseded || replacement.Status != models.KnowledgeStatusPublished {
		t.Fatalf("原子替代状态错误: current=%s replacement=%s", current.Status, replacement.Status)
	}
	body = fmt.Sprintf(`{"version":"v0.6","items":[{"document_id":%d,"restore_document_id":%d}]}`, replacement.ID, current.ID)
	response = performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/rollback", body)
	if response.Code != http.StatusOK {
		t.Fatalf("合法批次回滚失败: status=%d body=%s", response.Code, response.Body.String())
	}
	if err := db.First(&current, current.ID).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.First(&replacement, replacement.ID).Error; err != nil {
		t.Fatal(err)
	}
	if current.Status != models.KnowledgeStatusPublished || current.SupersededByID != nil || replacement.Status != models.KnowledgeStatusRevoked {
		t.Fatalf("原子回滚状态错误: current=%#v replacement=%s", current, replacement.Status)
	}
}

func validInspectedKnowledgeDocument(title, content string) models.AIKnowledgeDocument {
	effectiveFrom := time.Date(2026, time.January, 1, 0, 0, 0, 0, time.UTC)
	hash := sha256.Sum256([]byte(content))
	return models.AIKnowledgeDocument{
		Title: title, SourceType: "official", SourceURI: "https://example.edu/policy",
		DocumentType: "school_policy", Department: "教务处", EffectiveFrom: &effectiveFrom,
		Content: content, ContentHash: fmt.Sprintf("%x", hash), Status: models.KnowledgeStatusInspected, CreatedBy: 18,
	}
}
