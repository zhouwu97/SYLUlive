package handlers

import (
	"context"
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
	"gorm.io/gorm/clause"
	"shenliyuan/internal/middleware"

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

type knowledgeReleaseItem struct {
	DocumentID           uint `json:"document_id"`
	SupersedesDocumentID uint `json:"supersedes_document_id,omitempty"`
}

type knowledgeReleaseRequest struct {
	Version string                 `json:"version"`
	Items   []knowledgeReleaseItem `json:"items"`
}

type knowledgeRollbackItem struct {
	DocumentID        uint `json:"document_id"`
	RestoreDocumentID uint `json:"restore_document_id,omitempty"`
}

type knowledgeRollbackRequest struct {
	Version string                  `json:"version"`
	Items   []knowledgeRollbackItem `json:"items"`
}

func (h *AIKnowledgeHandler) Import(c *gin.Context) {
	request, err := h.decodeKnowledgeImport(c)
	if err != nil {
		if middleware.IsRequestBodyTooLarge(err) {
			c.JSON(http.StatusRequestEntityTooLarge, gin.H{"code": "request_body_too_large", "message": "请求体超过大小限制"})
			return
		}
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
	status := models.KnowledgeStatusDraft
	if isCrawlerKnowledgeSource(request.SourceType) {
		status = models.KnowledgeStatusNeedsReview
	}
	document := models.AIKnowledgeDocument{
		Title: request.Title, SourceType: request.SourceType, SourceURI: request.SourceURI,
		SourceFileName: request.SourceFileName, DocumentType: request.DocumentType,
		Department: request.Department, EffectiveFrom: effectiveFrom, EffectiveTo: effectiveTo,
		Content: request.Content, ContentHash: hex.EncodeToString(hash[:]),
		Status: status, CreatedBy: c.GetUint("user_id"),
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
	if beforeID, err := strconv.ParseUint(c.Query("before_id"), 10, 64); err == nil && beforeID > 0 {
		query = query.Where("id < ?", beforeID)
	}
	if status := strings.TrimSpace(c.Query("status")); status != "" {
		query = query.Where("status = ?", status)
	}
	var documents []models.AIKnowledgeDocument
	if err := query.Find(&documents).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_list_failed", "message": "读取知识文档失败"})
		return
	}
	var nextBeforeID uint
	if len(documents) == limit {
		nextBeforeID = documents[len(documents)-1].ID
	}
	c.JSON(http.StatusOK, gin.H{"documents": documents, "next_before_id": nextBeforeID})
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
	report, err := services.InspectKnowledgeDocument(c.Request.Context(), h.db, document)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_inspect_failed", "message": "检查知识文档失败"})
		return
	}
	inspectionBytes, _ := json.Marshal(report)
	document.Inspection = string(inspectionBytes)
	if report.HasBlockingIssues() {
		document.Status = models.KnowledgeStatusNeedsReview
		if err := h.db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Save(&document).Error; err != nil {
				return err
			}
			return createKnowledgeAudit(tx, c, document.ID, "inspect_blocked", document.Inspection)
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_inspect_failed", "message": "检查知识文档失败"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"document": document, "inspection": report})
		return
	}
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
	documentID, ok := parseKnowledgeID(c)
	if !ok {
		return
	}
	var document models.AIKnowledgeDocument
	err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := lockKnowledgeDocument(tx, documentID, &document); err != nil {
			return err
		}
		if document.Status != models.KnowledgeStatusInspected {
			return errKnowledgeNotInspected
		}
		if err := h.validateKnowledgeReleaseCandidate(c.Request.Context(), tx, document, 0); err != nil {
			return err
		}
		now := time.Now()
		document.Status = models.KnowledgeStatusPublished
		document.PublishedAt = &now
		document.ReviewedBy = c.GetUint("user_id")
		if err := tx.Save(&document).Error; err != nil {
			return err
		}
		return createKnowledgeAudit(tx, c, document.ID, "publish", "")
	})
	if h.writeKnowledgeReleaseError(c, err) {
		return
	}
	if err != nil {
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
		if err := lockKnowledgeDocument(tx, id, &current); err != nil {
			return err
		}
		if err := lockKnowledgeDocument(tx, request.ReplacementDocumentID, &replacement); err != nil {
			return err
		}
		if current.ID == replacement.ID || current.Status != models.KnowledgeStatusPublished || replacement.Status != models.KnowledgeStatusInspected {
			return errKnowledgeStatusConflict
		}
		if replacement.DocumentType != current.DocumentType {
			return errKnowledgeStatusConflict
		}
		if err := h.validateKnowledgeReleaseCandidate(c.Request.Context(), tx, replacement, current.ID); err != nil {
			return err
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
	if h.writeKnowledgeReleaseError(c, err) {
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_supersede_failed", "message": "替代知识文档失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"document": current, "replacement": replacement})
}

// ReleaseBatch 在一个事务中发布整批候选并完成对应的 supersede，避免部分版本生效。
func (h *AIKnowledgeHandler) ReleaseBatch(c *gin.Context) {
	if !requireKnowledgePublishPermission(c) {
		return
	}
	var request knowledgeReleaseRequest
	if err := decodeStrictJSON(c, &request, 1<<20); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "发布批次请求格式错误"})
		return
	}
	request.Version = strings.TrimSpace(request.Version)
	if request.Version == "" || len(request.Version) > 32 || len(request.Items) == 0 || len(request.Items) > 200 {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "knowledge_release_invalid", "message": "版本或发布项无效"})
		return
	}

	var published []models.AIKnowledgeDocument
	err := h.db.Transaction(func(tx *gorm.DB) error {
		seenDocuments := make(map[uint]struct{}, len(request.Items))
		seenSuperseded := make(map[uint]struct{}, len(request.Items))
		candidates := make([]models.AIKnowledgeDocument, len(request.Items))
		currents := make([]*models.AIKnowledgeDocument, len(request.Items))
		for index, item := range request.Items {
			if item.DocumentID == 0 {
				return errKnowledgeStatusConflict
			}
			if _, exists := seenDocuments[item.DocumentID]; exists {
				return errKnowledgeStatusConflict
			}
			seenDocuments[item.DocumentID] = struct{}{}
			if err := lockKnowledgeDocument(tx, item.DocumentID, &candidates[index]); err != nil {
				return err
			}
			if candidates[index].Status != models.KnowledgeStatusInspected {
				return errKnowledgeNotInspected
			}
			if item.SupersedesDocumentID != 0 {
				if item.SupersedesDocumentID == item.DocumentID {
					return errKnowledgeStatusConflict
				}
				if _, exists := seenSuperseded[item.SupersedesDocumentID]; exists {
					return errKnowledgeStatusConflict
				}
				seenSuperseded[item.SupersedesDocumentID] = struct{}{}
				current := &models.AIKnowledgeDocument{}
				if err := lockKnowledgeDocument(tx, item.SupersedesDocumentID, current); err != nil {
					return err
				}
				if current.Status != models.KnowledgeStatusPublished || current.DocumentType != candidates[index].DocumentType {
					return errKnowledgeStatusConflict
				}
				currents[index] = current
			}
			if err := h.validateKnowledgeReleaseCandidate(c.Request.Context(), tx, candidates[index], item.SupersedesDocumentID); err != nil {
				return err
			}
		}

		now := time.Now()
		for index := range candidates {
			candidate := &candidates[index]
			if current := currents[index]; current != nil {
				current.Status, current.SupersededByID, current.ReviewedBy = models.KnowledgeStatusSuperseded, &candidate.ID, c.GetUint("user_id")
				if err := tx.Save(current).Error; err != nil {
					return err
				}
				if err := createKnowledgeAudit(tx, c, current.ID, "supersede", request.Version+":"+strconv.FormatUint(uint64(candidate.ID), 10)); err != nil {
					return err
				}
			}
			candidate.Status, candidate.PublishedAt, candidate.ReviewedBy = models.KnowledgeStatusPublished, &now, c.GetUint("user_id")
			if err := tx.Save(candidate).Error; err != nil {
				return err
			}
			action := "publish_release"
			if currents[index] != nil {
				action = "publish_as_replacement"
			}
			if err := createKnowledgeAudit(tx, c, candidate.ID, action, request.Version); err != nil {
				return err
			}
		}
		published = candidates
		return nil
	})
	if h.writeKnowledgeReleaseError(c, err) {
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_release_failed", "message": "知识库批次发布失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"version": request.Version, "documents": published})
}

// RollbackBatch 原子撤销一个发布批次，并恢复被该批次替代的旧文档。
func (h *AIKnowledgeHandler) RollbackBatch(c *gin.Context) {
	if !requireKnowledgePublishPermission(c) {
		return
	}
	var request knowledgeRollbackRequest
	if err := decodeStrictJSON(c, &request, 1<<20); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"code": "invalid_request", "message": "回滚批次请求格式错误"})
		return
	}
	request.Version = strings.TrimSpace(request.Version)
	if request.Version == "" || len(request.Version) > 32 || len(request.Items) == 0 || len(request.Items) > 200 {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"code": "knowledge_rollback_invalid", "message": "版本或回滚项无效"})
		return
	}
	err := h.db.Transaction(func(tx *gorm.DB) error {
		published := make([]models.AIKnowledgeDocument, len(request.Items))
		restores := make([]*models.AIKnowledgeDocument, len(request.Items))
		seen := make(map[uint]struct{}, len(request.Items)*2)
		for index, item := range request.Items {
			if item.DocumentID == 0 {
				return errKnowledgeStatusConflict
			}
			if _, exists := seen[item.DocumentID]; exists {
				return errKnowledgeStatusConflict
			}
			seen[item.DocumentID] = struct{}{}
			if err := lockKnowledgeDocument(tx, item.DocumentID, &published[index]); err != nil {
				return err
			}
			if published[index].Status != models.KnowledgeStatusPublished {
				return errKnowledgeStatusConflict
			}
			if item.RestoreDocumentID != 0 {
				if _, exists := seen[item.RestoreDocumentID]; exists {
					return errKnowledgeStatusConflict
				}
				seen[item.RestoreDocumentID] = struct{}{}
				restore := &models.AIKnowledgeDocument{}
				if err := lockKnowledgeDocument(tx, item.RestoreDocumentID, restore); err != nil {
					return err
				}
				if restore.Status != models.KnowledgeStatusSuperseded || restore.SupersededByID == nil || *restore.SupersededByID != item.DocumentID {
					return errKnowledgeStatusConflict
				}
				restores[index] = restore
			}
		}
		now := time.Now()
		for index := range published {
			published[index].Status, published[index].RevokedAt, published[index].ReviewedBy = models.KnowledgeStatusRevoked, &now, c.GetUint("user_id")
			if err := tx.Save(&published[index]).Error; err != nil {
				return err
			}
			if err := createKnowledgeAudit(tx, c, published[index].ID, "rollback_revoke", request.Version); err != nil {
				return err
			}
			if restore := restores[index]; restore != nil {
				restore.Status, restore.SupersededByID, restore.ReviewedBy = models.KnowledgeStatusPublished, nil, c.GetUint("user_id")
				if err := tx.Save(restore).Error; err != nil {
					return err
				}
				if err := createKnowledgeAudit(tx, c, restore.ID, "rollback_restore", request.Version); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if h.writeKnowledgeReleaseError(c, err) {
		return
	}
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"code": "knowledge_rollback_failed", "message": "知识库批次回滚失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"version": request.Version, "rolled_back": len(request.Items)})
}

var errKnowledgeStatusConflict = errors.New("knowledge status conflict")
var errKnowledgeNotInspected = errors.New("knowledge not inspected")
var errKnowledgeGovernanceBlocked = errors.New("knowledge governance blocked")
var errKnowledgeDuplicatePublished = errors.New("knowledge duplicate published")
var errKnowledgeRequiresSupersede = errors.New("knowledge requires supersede")
var errKnowledgeNotIndexed = errors.New("knowledge not indexed")
var errKnowledgeIndexVersionDrift = errors.New("knowledge index version drift")

func (h *AIKnowledgeHandler) validateKnowledgeReleaseCandidate(ctx context.Context, tx *gorm.DB, document models.AIKnowledgeDocument, allowedSupersededID uint) error {
	report, err := services.InspectKnowledgeDocument(ctx, tx, document)
	if err != nil {
		return err
	}
	if report.HasBlockingIssues() {
		for _, issue := range report.Issues {
			if issue.Code == "duplicate_content_hash" {
				return errKnowledgeDuplicatePublished
			}
		}
		return errKnowledgeGovernanceBlocked
	}
	if report.RequiresSupersede() {
		if allowedSupersededID == 0 {
			return errKnowledgeRequiresSupersede
		}
		for _, issue := range report.Issues {
			if issue.Severity != services.KnowledgeIssueRequiresReplace {
				continue
			}
			for _, relatedID := range issue.RelatedDocumentIDs {
				if relatedID != allowedSupersededID {
					return errKnowledgeRequiresSupersede
				}
			}
		}
	}
	if h.rag != nil {
		var chunkCount int64
		if err := tx.Model(&models.AIKnowledgeChunk{}).Where("document_id = ?", document.ID).Count(&chunkCount).Error; err != nil {
			return err
		}
		if chunkCount == 0 {
			return errKnowledgeNotIndexed
		}
		var inspection services.KnowledgeInspectionReport
		if json.Unmarshal([]byte(document.Inspection), &inspection) != nil || inspection.ChunkCount != int(chunkCount) ||
			inspection.ChunkingVersion == "" || inspection.EmbeddingModelVersion == "" || inspection.EmbeddingDimensions <= 0 {
			return errKnowledgeIndexVersionDrift
		}
		var activeModels []models.AIEmbeddingModelRegistry
		if err := tx.Where("active = ?", true).Find(&activeModels).Error; err != nil {
			return err
		}
		if len(activeModels) != 1 || activeModels[0].Version != inspection.EmbeddingModelVersion ||
			activeModels[0].ModelName != inspection.EmbeddingModelName || activeModels[0].Dimensions != inspection.EmbeddingDimensions {
			return errKnowledgeIndexVersionDrift
		}
		var chunkVersions []string
		if err := tx.Model(&models.AIKnowledgeChunk{}).Where("document_id = ?", document.ID).
			Distinct().Pluck("embedding_model_version", &chunkVersions).Error; err != nil {
			return err
		}
		if len(chunkVersions) != 1 || chunkVersions[0] != activeModels[0].Version {
			return errKnowledgeIndexVersionDrift
		}
		var shadowCount int64
		if err := tx.Model(&models.AIKnowledgeChunkEmbedding{}).
			Joins("JOIN ai_knowledge_chunks c ON c.id = ai_knowledge_chunk_embeddings.chunk_id").
			Where("c.document_id = ? AND ai_knowledge_chunk_embeddings.model_version = ?", document.ID, activeModels[0].Version).
			Count(&shadowCount).Error; err != nil {
			return err
		}
		if shadowCount != chunkCount {
			return errKnowledgeIndexVersionDrift
		}
	}
	return nil
}

func (h *AIKnowledgeHandler) writeKnowledgeReleaseError(c *gin.Context, err error) bool {
	if err == nil {
		return false
	}
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(http.StatusNotFound, gin.H{"code": "knowledge_not_found", "message": "知识文档不存在"})
	case errors.Is(err, errKnowledgeNotInspected):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_not_inspected", "message": "文档必须先完成检查"})
	case errors.Is(err, errKnowledgeNotIndexed):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_not_indexed", "message": "文档必须完成 LangChain 分块与向量索引后才能发布"})
	case errors.Is(err, errKnowledgeIndexVersionDrift):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_index_version_drift", "message": "分块器、embedding 或活动索引版本发生漂移"})
	case errors.Is(err, errKnowledgeDuplicatePublished):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_duplicate_content", "message": "相同内容 hash 已存在，禁止重复发布"})
	case errors.Is(err, errKnowledgeRequiresSupersede):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_requires_supersede", "message": "存在冲突的已发布版本，必须通过 supersede 原子替代"})
	case errors.Is(err, errKnowledgeGovernanceBlocked):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_governance_blocked", "message": "文档仍有阻塞治理问题"})
	case errors.Is(err, errKnowledgeStatusConflict):
		c.JSON(http.StatusConflict, gin.H{"code": "knowledge_status_conflict", "message": "知识文档状态或替代关系无效"})
	default:
		return false
	}
	return true
}

func lockKnowledgeDocument(tx *gorm.DB, id uint, target *models.AIKnowledgeDocument) error {
	query := tx
	if tx.Dialector.Name() == "postgres" {
		query = query.Clauses(clause.Locking{Strength: "UPDATE"})
	}
	return query.First(target, id).Error
}

func isCrawlerKnowledgeSource(sourceType string) bool {
	normalized := strings.ToLower(strings.TrimSpace(sourceType))
	return strings.Contains(normalized, "crawl") || strings.Contains(normalized, "spider")
}

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
