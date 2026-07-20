package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/academiccalendar"
	"shenliyuan/internal/ai"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const maxKnowledgeDocumentBytes = 2 << 20

type AIKnowledgeHandler struct {
	db  *gorm.DB
	rag *ai.RAGClient
}

func NewAIKnowledgeHandler(db *gorm.DB, ragClients ...*ai.RAGClient) *AIKnowledgeHandler {
	var rag *ai.RAGClient
	if len(ragClients) > 0 {
		rag = ragClients[0]
	}
	return &AIKnowledgeHandler{db: db, rag: rag}
}

type knowledgeImportRequest struct {
	Title          string `json:"title"`
	SourceType     string `json:"source_type"`
	SourceURI      string `json:"source_uri"`
	SourceFileName string `json:"source_file_name"`
	DocumentType   string `json:"document_type"`
	Department     string `json:"department"`
	EffectiveFrom  string `json:"effective_from"`
	EffectiveTo    string `json:"effective_to"`
	Content        string `json:"content"`
}

type knowledgeSupersedeRequest struct {
	ReplacementDocumentID uint `json:"replacement_document_id"`
}

func (h *AIKnowledgeHandler) Import(c *gin.Context) {
	request, err := h.decodeKnowledgeImport(c)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "知识文档请求格式错误"})
		return
	}
	request.Title = strings.TrimSpace(request.Title)
	request.SourceType = strings.TrimSpace(request.SourceType)
	request.SourceURI = strings.TrimSpace(request.SourceURI)
	request.SourceFileName = strings.TrimSpace(request.SourceFileName)
	request.DocumentType = strings.TrimSpace(request.DocumentType)
	request.Department = strings.TrimSpace(request.Department)
	request.Content = strings.TrimSpace(request.Content)
	if request.Title == "" || request.SourceType == "" || request.Content == "" {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "knowledge_document_invalid", "message": "标题、来源类型和正文不能为空"})
		return
	}
	if utf8.RuneCountInString(request.Title) > 255 || len(request.Content) > maxKnowledgeDocumentBytes {
		c.JSON(http.StatusRequestEntityTooLarge, gin.H{"code": "knowledge_document_too_large", "message": "知识文档超过大小限制"})
		return
	}
	effectiveFrom, err := parseOptionalKnowledgeDate(request.EffectiveFrom)
	if err != nil {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "knowledge_effective_date_invalid", "message": "生效日期格式无效"})
		return
	}
	effectiveTo, err := parseOptionalKnowledgeDate(request.EffectiveTo)
	if err != nil || (effectiveFrom != nil && effectiveTo != nil && effectiveTo.Before(*effectiveFrom)) {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "knowledge_effective_date_invalid", "message": "失效日期格式或范围无效"})
		return
	}
	hash := sha256.Sum256([]byte(request.Content))
	document := models.AIKnowledgeDocument{
		Title: request.Title, SourceType: request.SourceType, SourceURI: request.SourceURI,
		SourceFileName: request.SourceFileName, DocumentType: request.DocumentType,
		Department: request.Department, EffectiveFrom: effectiveFrom, EffectiveTo: effectiveTo,
		Content: request.Content, ContentHash: hex.EncodeToString(hash[:]),
		Status: models.KnowledgeStatusDraft, CreatedBy: c.GetUint("user_id"),
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Create(&document).Error; err != nil {
			return err
		}
		return createKnowledgeAudit(tx, c, document.ID, "import", "")
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_import_failed", "message": "导入知识文档失败"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"document": document})
}

func (h *AIKnowledgeHandler) decodeKnowledgeImport(c *gin.Context) (knowledgeImportRequest, error) {
	var request knowledgeImportRequest
	if !strings.HasPrefix(strings.ToLower(c.GetHeader("Content-Type")), "multipart/form-data") {
		return request, decodeStrictJSON(c, &request, maxKnowledgeDocumentBytes)
	}
	if h.rag == nil {
		return request, errors.New("RAG parser unavailable")
	}
	if err := c.Request.ParseMultipartForm(8 << 20); err != nil {
		return request, err
	}
	fileHeader, err := c.FormFile("file")
	if err != nil {
		return request, err
	}
	file, err := fileHeader.Open()
	if err != nil {
		return request, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, (8<<20)+1))
	if err != nil || len(raw) > 8<<20 {
		return request, errors.New("knowledge file exceeds limit")
	}
	sourceType := strings.TrimPrefix(strings.ToLower(filepath.Ext(fileHeader.Filename)), ".")
	if sourceType == "" {
		sourceType = strings.TrimSpace(c.PostForm("source_type"))
	}
	if sourceType == "txt" {
		sourceType = "text"
	}
	if sourceType != "text" && sourceType != "html" && sourceType != "htm" && sourceType != "pdf" && sourceType != "docx" {
		return request, errors.New("unsupported knowledge file type")
	}
	content, err := h.rag.ParseDocument(c.Request.Context(), sourceType, filepath.Base(fileHeader.Filename), raw)
	if err != nil {
		return request, err
	}
	request = knowledgeImportRequest{
		Title: c.PostForm("title"), SourceType: sourceType, SourceURI: c.PostForm("source_uri"),
		SourceFileName: filepath.Base(fileHeader.Filename), DocumentType: c.PostForm("document_type"),
		Department: c.PostForm("department"), EffectiveFrom: c.PostForm("effective_from"),
		EffectiveTo: c.PostForm("effective_to"), Content: content,
	}
	return request, nil
}

func parseOptionalKnowledgeDate(value string) (*time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, nil
	}
	if parsed, err := time.Parse(time.RFC3339, value); err == nil {
		return &parsed, nil
	}
	if academiccalendar.ShanghaiLocation == nil {
		return nil, errors.New("Asia/Shanghai timezone unavailable")
	}
	parsed, err := time.ParseInLocation("2006-01-02", value, academiccalendar.ShanghaiLocation)
	if err != nil {
		return nil, err
	}
	return &parsed, nil
}

func (h *AIKnowledgeHandler) List(c *gin.Context) {
	limit := 50
	if parsed, err := strconv.Atoi(c.Query("limit")); err == nil && parsed > 0 && parsed <= 100 {
		limit = parsed
	}
	query := h.db.Order("id DESC").Limit(limit)
	if status := strings.TrimSpace(c.Query("status")); status != "" {
		query = query.Where("status = ?", status)
	}
	var documents []models.AIKnowledgeDocument
	if err := query.Find(&documents).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_list_failed", "message": "读取知识文档失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"documents": documents})
}

func (h *AIKnowledgeHandler) Read(c *gin.Context) {
	document, ok := h.findDocument(c)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{"document": document, "content": document.Content})
}

func (h *AIKnowledgeHandler) Inspect(c *gin.Context) {
	if !requireEmptyKnowledgeActionBody(c) {
		return
	}
	document, ok := h.findDocument(c)
	if !ok {
		return
	}
	if document.Status == models.KnowledgeStatusPublished || document.Status == models.KnowledgeStatusRevoked || document.Status == models.KnowledgeStatusSuperseded {
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_status_conflict", "message": "当前状态不能重新检查"})
		return
	}
	inspectionBytes, _ := json.Marshal(gin.H{
		"bytes": len(document.Content), "runes": utf8.RuneCountInString(document.Content),
		"content_hash": document.ContentHash, "unresolved_items": []string{},
	})
	document.Inspection = string(inspectionBytes)
	if h.rag != nil {
		document.Status = models.KnowledgeStatusIndexing
		if err := h.db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Save(&document).Error; err != nil {
				return err
			}
			if _, err := services.EnqueueKnowledgeIngestion(tx, document.ID, models.KnowledgeStatusInspected); err != nil {
				return err
			}
			return createKnowledgeAudit(tx, c, document.ID, "inspect_and_index", document.Inspection)
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_inspect_failed", "message": "提交知识文档检查失败"})
			return
		}
		c.JSON(http.StatusAccepted, gin.H{"document": document})
		return
	}
	document.Status = models.KnowledgeStatusInspected
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Save(&document).Error; err != nil {
			return err
		}
		return createKnowledgeAudit(tx, c, document.ID, "inspect", document.Inspection)
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_inspect_failed", "message": "检查知识文档失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"document": document})
}

func (h *AIKnowledgeHandler) Reindex(c *gin.Context) {
	if !requireEmptyKnowledgeActionBody(c) {
		return
	}
	document, ok := h.findDocument(c)
	if !ok {
		return
	}
	if document.Status == models.KnowledgeStatusRevoked || document.Status == models.KnowledgeStatusSuperseded {
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_status_conflict", "message": "已撤销或被替代文档不能重建索引"})
		return
	}
	now := time.Now()
	document.ReindexRequestedAt = &now
	restoreStatus := document.Status
	if h.rag != nil && document.Status != models.KnowledgeStatusPublished {
		document.Status = models.KnowledgeStatusIndexing
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Save(&document).Error; err != nil {
			return err
		}
		if h.rag != nil {
			if _, err := services.EnqueueKnowledgeIngestion(tx, document.ID, restoreStatus); err != nil {
				return err
			}
		}
		return createKnowledgeAudit(tx, c, document.ID, "reindex", "")
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_reindex_failed", "message": "提交重建索引任务失败"})
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"document": document})
}

func (h *AIKnowledgeHandler) Publish(c *gin.Context) {
	if !requireKnowledgePublishPermission(c) {
		return
	}
	if !requireEmptyKnowledgeActionBody(c) {
		return
	}
	document, ok := h.findDocument(c)
	if !ok {
		return
	}
	if document.Status != models.KnowledgeStatusInspected {
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_not_inspected", "message": "文档必须先完成检查"})
		return
	}
	if h.rag != nil {
		var chunkCount int64
		if err := h.db.Model(&models.AIKnowledgeChunk{}).Where("document_id = ?", document.ID).Count(&chunkCount).Error; err != nil || chunkCount == 0 {
			c.JSON(http.StatusConflict, gin.H{"code": "knowledge_not_indexed", "message": "文档必须完成索引后才能发布"})
			return
		}
	}
	now := time.Now()
	document.Status = models.KnowledgeStatusPublished
	document.PublishedAt = &now
	document.ReviewedBy = c.GetUint("user_id")
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Save(&document).Error; err != nil {
			return err
		}
		return createKnowledgeAudit(tx, c, document.ID, "publish", "")
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_publish_failed", "message": "发布知识文档失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"document": document})
}

func (h *AIKnowledgeHandler) Revoke(c *gin.Context) {
	if !requireKnowledgePublishPermission(c) {
		return
	}
	if !requireEmptyKnowledgeActionBody(c) {
		return
	}
	document, ok := h.findDocument(c)
	if !ok {
		return
	}
	if document.Status != models.KnowledgeStatusPublished {
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_status_conflict", "message": "只有已发布文档可以撤销"})
		return
	}
	now := time.Now()
	document.Status, document.RevokedAt, document.ReviewedBy = models.KnowledgeStatusRevoked, &now, c.GetUint("user_id")
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Save(&document).Error; err != nil {
			return err
		}
		return createKnowledgeAudit(tx, c, document.ID, "revoke", "")
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_revoke_failed", "message": "撤销知识文档失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"document": document})
}

func (h *AIKnowledgeHandler) Supersede(c *gin.Context) {
	if !requireKnowledgePublishPermission(c) {
		return
	}
	var request knowledgeSupersedeRequest
	if err := decodeStrictJSON(c, &request, 16<<10); err != nil || request.ReplacementDocumentID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "必须指定替代文档 ID"})
		return
	}
	id, ok := parseKnowledgeID(c)
	if !ok {
		return
	}
	var current, replacement models.AIKnowledgeDocument
	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.First(&current, id).Error; err != nil {
			return err
		}
		if err := tx.First(&replacement, request.ReplacementDocumentID).Error; err != nil {
			return err
		}
		if current.Status != models.KnowledgeStatusPublished || replacement.Status != models.KnowledgeStatusInspected {
			return errKnowledgeStatusConflict
		}
		if h.rag != nil {
			var chunkCount int64
			if err := tx.Model(&models.AIKnowledgeChunk{}).Where("document_id = ?", replacement.ID).Count(&chunkCount).Error; err != nil {
				return err
			}
			if chunkCount == 0 {
				return errKnowledgeStatusConflict
			}
		}
		now := time.Now()
		current.Status, current.SupersededByID, current.ReviewedBy = models.KnowledgeStatusSuperseded, &replacement.ID, c.GetUint("user_id")
		replacement.Status, replacement.PublishedAt, replacement.ReviewedBy = models.KnowledgeStatusPublished, &now, c.GetUint("user_id")
		if err := tx.Save(&current).Error; err != nil {
			return err
		}
		if err := tx.Save(&replacement).Error; err != nil {
			return err
		}
		if err := createKnowledgeAudit(tx, c, current.ID, "supersede", strconv.FormatUint(uint64(replacement.ID), 10)); err != nil {
			return err
		}
		return createKnowledgeAudit(tx, c, replacement.ID, "publish_as_replacement", strconv.FormatUint(uint64(current.ID), 10))
	})
	if errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusNotFound, gin.H{"code": "knowledge_not_found", "message": "知识文档不存在"})
		return
	}
	if errors.Is(err, errKnowledgeStatusConflict) {
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_status_conflict", "message": "原文档必须已发布，替代文档必须已检查"})
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_supersede_failed", "message": "替代知识文档失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"document": current, "replacement": replacement})
}

var errKnowledgeStatusConflict = errors.New("knowledge status conflict")

func requireKnowledgePublishPermission(c *gin.Context) bool {
	role := models.Role(c.GetString("role"))
	if role != models.RoleSuperAdmin {
		c.JSON(http.StatusForbidden, gin.H{"code": "super_admin_required", "message": "该操作仅限超级管理员"})
		return false
	}
	return true
}

func (h *AIKnowledgeHandler) findDocument(c *gin.Context) (models.AIKnowledgeDocument, bool) {
	id, ok := parseKnowledgeID(c)
	if !ok {
		return models.AIKnowledgeDocument{}, false
	}
	var document models.AIKnowledgeDocument
	if err := h.db.First(&document, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"code": "knowledge_not_found", "message": "知识文档不存在"})
		} else {
			c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_read_failed", "message": "读取知识文档失败"})
		}
		return models.AIKnowledgeDocument{}, false
	}
	return document, true
}

func parseKnowledgeID(c *gin.Context) (uint, bool) {
	value, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || value == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_document_id", "message": "知识文档 ID 无效"})
		return 0, false
	}
	return uint(value), true
}

func createKnowledgeAudit(tx *gorm.DB, c *gin.Context, documentID uint, action, detail string) error {
	return tx.Create(&models.AIKnowledgeAuditLog{
		DocumentID: documentID, ActorUserID: c.GetUint("user_id"),
		ActorRole: c.GetString("role"), Action: action, Detail: detail,
	}).Error
}

func decodeStrictJSON(c *gin.Context, target interface{}, maxBytes int64) error {
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(&struct{}{}) == nil {
		return errors.New("multiple JSON values")
	}
	return nil
}

func requireEmptyKnowledgeActionBody(c *gin.Context) bool {
	body, err := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, 16<<10))
	if err != nil || strings.TrimSpace(string(body)) != "" {
		c.JSON(http.StatusBadRequest, gin.H{"code": "unexpected_action_body", "message": "该动作不接受请求体，操作者身份仅来自认证信息"})
		return false
	}
	return true
}
