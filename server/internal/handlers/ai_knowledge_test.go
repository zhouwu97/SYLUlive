package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func newKnowledgeTestRouter(t *testing.T, role models.Role, userID uint) (*gin.Engine, *gorm.DB) {
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
	if err := db.AutoMigrate(&models.AIKnowledgeDocument{}, &models.AIKnowledgeAuditLog{}); err != nil {
		t.Fatal(err)
	}
	handler := NewAIKnowledgeHandler(db)
	router := gin.New()
	group := router.Group("/api/admin/ai/knowledge")
	group.Use(func(c *gin.Context) {
		c.Set("user_id", userID)
		c.Set("role", string(role))
	})
	group.POST("/import", handler.Import)
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
	response := performKnowledgeRequest(router, http.MethodPost, "/api/admin/ai/knowledge/import", `{"title":"学生手册","source_type":"official","source_uri":"https://example.edu/handbook","content":"请假应按学校流程办理。"}`)
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
	document := models.AIKnowledgeDocument{
		Title: "校规", SourceType: "official", Content: "正文", ContentHash: "hash",
		Status: models.KnowledgeStatusInspected, CreatedBy: 18,
	}
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
	document := models.AIKnowledgeDocument{
		Title: "校规", SourceType: "official", Content: "正文", ContentHash: "hash",
		Status: models.KnowledgeStatusInspected, CreatedBy: 18,
	}
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
