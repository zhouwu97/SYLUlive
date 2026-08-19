package handlers

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

const maxCompetitionCatalogBytes = 12 << 20

type competitionLegacyResolutionDTO struct {
	ID                      uint      `json:"id"`
	IdentityHash            string    `json:"identity_hash"`
	CanonicalEventID        uint      `json:"canonical_event_id"`
	CanonicalCompetitionID  string    `json:"canonical_competition_id"`
	CanonicalTitle          string    `json:"canonical_title"`
	DuplicateEventID        uint      `json:"duplicate_event_id"`
	Reason                  string    `json:"reason"`
	DuplicatePreviousStatus string    `json:"duplicate_previous_status"`
	ResolvedBy              uint      `json:"resolved_by"`
	ResolvedAt              time.Time `json:"resolved_at"`
}

func (h *CompetitionHandler) AdminValidateCompetitionCatalog(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	document, ok := decodeCompetitionCatalogRequest(c)
	if !ok {
		return
	}
	importer := services.NewCompetitionCatalogImporter(h.db)
	result := importer.Validate(document)
	status := http.StatusOK
	if result.Status != "passed" {
		status = http.StatusUnprocessableEntity
	}
	_ = h.db.Create(&models.CompetitionCatalogAuditLog{
		ActorUserID: userID, Action: "catalog_validate", Result: result.Status,
		Detail: document.DatasetVersion,
	}).Error
	c.JSON(status, result)
}

func (h *CompetitionHandler) AdminImportCompetitionCatalog(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	document, ok := decodeCompetitionCatalogRequest(c)
	if !ok {
		return
	}
	catalog, validation, err := services.NewCompetitionCatalogImporter(h.db).
		Import(c.Request.Context(), document, userID)
	if err != nil {
		if errors.Is(err, services.ErrCatalogValidationFailed) {
			c.JSON(http.StatusUnprocessableEntity, validation)
			return
		}
		c.JSON(http.StatusConflict, gin.H{"error": "目录版本或摘要已存在"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"package": catalog, "validation": validation})
}

func (h *CompetitionHandler) AdminExportCompetitionCatalogBaseline(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	document, validation, err := services.NewCompetitionCatalogBaselineExporter(h.db).
		Export(c.Request.Context())
	if err != nil {
		result := "failed"
		status := http.StatusInternalServerError
		message := "导出旧目录基线失败"
		switch {
		case errors.Is(err, services.ErrCatalogBaselineAlreadyExists):
			status = http.StatusConflict
			message = "已有活动目录包，不能重复建立首次激活基线"
		case errors.Is(err, services.ErrCatalogBaselineEmpty):
			status = http.StatusConflict
			message = "没有可导出的旧目录公开赛事"
		case errors.Is(err, services.ErrCatalogValidationFailed):
			status = http.StatusUnprocessableEntity
			message = "旧目录基线未通过服务端校验"
			result = "rejected"
		}
		_ = h.db.Create(&models.CompetitionCatalogAuditLog{
			ActorUserID: userID, Action: "catalog_baseline_export", Result: result,
			Detail: message,
		}).Error
		if errors.Is(err, services.ErrCatalogValidationFailed) {
			c.JSON(status, gin.H{"error": message, "validation": validation})
			return
		}
		c.JSON(status, gin.H{"error": message})
		return
	}
	_ = h.db.Create(&models.CompetitionCatalogAuditLog{
		ActorUserID: userID, Action: "catalog_baseline_export", Result: "success",
		Detail: document.DatasetVersion,
	}).Error
	c.Header("Content-Disposition", "attachment; filename=legacy-production-baseline.json")
	c.Header("X-Catalog-Package-Hash", document.PackageHash)
	c.JSON(http.StatusOK, document)
}

func (h *CompetitionHandler) AdminExportCompetitionCatalogIdentityBaseline(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	document, validation, err := services.NewCompetitionCatalogBaselineExporter(h.db).
		ExportIdentity(c.Request.Context())
	if err != nil {
		result := "failed"
		status := http.StatusInternalServerError
		message := "导出旧赛事身份基线失败"
		switch {
		case errors.Is(err, services.ErrCatalogBaselineAlreadyExists):
			status = http.StatusConflict
			message = "已有活动目录包，不能重复建立首次身份基线"
		case errors.Is(err, services.ErrCatalogBaselineEmpty):
			status = http.StatusConflict
			message = "没有经过重复归并审计的 canonical 旧赛事"
		case errors.Is(err, services.ErrCatalogValidationFailed):
			status = http.StatusUnprocessableEntity
			message = "旧赛事身份基线未通过服务端校验"
			result = "rejected"
		}
		_ = h.db.Create(&models.CompetitionCatalogAuditLog{
			ActorUserID: userID, Action: "catalog_identity_baseline_export",
			Result: result, Detail: message,
		}).Error
		if errors.Is(err, services.ErrCatalogValidationFailed) {
			c.JSON(status, gin.H{"error": message, "validation": validation})
			return
		}
		c.JSON(status, gin.H{"error": message})
		return
	}
	_ = h.db.Create(&models.CompetitionCatalogAuditLog{
		ActorUserID: userID, Action: "catalog_identity_baseline_export",
		Result: "success", Detail: document.DatasetVersion,
	}).Error
	c.Header("Content-Disposition", "attachment; filename=legacy-identity-baseline-20260731.json")
	c.Header("X-Catalog-Package-Hash", document.PackageHash)
	c.JSON(http.StatusOK, document)
}

func (h *CompetitionHandler) AdminListCompetitionCatalogPackages(c *gin.Context) {
	var packages []models.CompetitionCatalogPackage
	if err := h.db.Order("id DESC").Find(&packages).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取目录包失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": packages})
}

func (h *CompetitionHandler) AdminListCompetitionLegacyResolutions(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "50"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 100 {
		pageSize = 50
	}
	query := h.db.Model(&models.CompetitionLegacyDuplicateResolution{})
	var total, identityGroups int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "统计历史归并失败"})
		return
	}
	if err := h.db.Model(&models.CompetitionLegacyDuplicateResolution{}).
		Distinct("identity_hash").Count(&identityGroups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "统计身份组失败"})
		return
	}
	var resolutions []models.CompetitionLegacyDuplicateResolution
	if err := query.Order("resolved_at DESC, id DESC").
		Offset((page - 1) * pageSize).Limit(pageSize).Find(&resolutions).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取历史归并失败"})
		return
	}
	canonicalIDs := make([]uint, 0, len(resolutions))
	for _, resolution := range resolutions {
		canonicalIDs = append(canonicalIDs, resolution.CanonicalEventID)
	}
	canonicalByID := make(map[uint]models.CompetitionEvent, len(canonicalIDs))
	if len(canonicalIDs) > 0 {
		var events []models.CompetitionEvent
		if err := h.db.Where("id IN ?", canonicalIDs).Find(&events).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "获取 canonical 赛事失败"})
			return
		}
		for _, event := range events {
			canonicalByID[event.ID] = event
		}
	}
	items := make([]competitionLegacyResolutionDTO, 0, len(resolutions))
	for _, resolution := range resolutions {
		canonical := canonicalByID[resolution.CanonicalEventID]
		items = append(items, competitionLegacyResolutionDTO{
			ID: resolution.ID, IdentityHash: resolution.IdentityHash,
			CanonicalEventID:       resolution.CanonicalEventID,
			CanonicalCompetitionID: canonical.CompetitionID, CanonicalTitle: canonical.Title,
			DuplicateEventID: resolution.DuplicateEventID, Reason: resolution.Reason,
			DuplicatePreviousStatus: resolution.DuplicatePreviousStatus,
			ResolvedBy:              resolution.ResolvedBy, ResolvedAt: resolution.ResolvedAt,
		})
	}
	totalPages := int((total + int64(pageSize) - 1) / int64(pageSize))
	if totalPages == 0 {
		totalPages = 1
	}
	c.JSON(http.StatusOK, gin.H{
		"items": items, "total": total, "identity_groups": identityGroups,
		"page": page, "page_size": pageSize, "total_pages": totalPages,
	})
}

func (h *CompetitionHandler) AdminGetCompetitionCatalogPackage(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var catalog models.CompetitionCatalogPackage
	if err := h.db.First(&catalog, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "目录包不存在"})
		return
	}
	c.JSON(http.StatusOK, catalog)
}

func (h *CompetitionHandler) AdminSuggestCompetitionCatalogLegacyMappings(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	packageID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	result, err := services.NewCompetitionCatalogLegacyMapper(h.db).
		Suggest(c.Request.Context(), packageID)
	if err != nil {
		h.respondCompetitionCatalogMappingError(c, err)
		return
	}
	h.writeCompetitionCatalogMappingAudit(packageID, userID, "catalog_mapping_suggest", "success")
	c.JSON(http.StatusOK, result)
}

func (h *CompetitionHandler) AdminListCompetitionCatalogLegacyMappings(c *gin.Context) {
	packageID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	items, err := services.NewCompetitionCatalogLegacyMapper(h.db).
		List(c.Request.Context(), packageID)
	if err != nil {
		h.respondCompetitionCatalogMappingError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": items})
}

func (h *CompetitionHandler) AdminReviewCompetitionCatalogLegacyMapping(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	packageID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	mappingID, ok := parseUintParam(c, "mapping_id")
	if !ok {
		return
	}
	var request services.CompetitionCatalogLegacyMappingReviewRequest
	if !decodeStrictJSONRequest(c, &request) {
		return
	}
	mapping, err := services.NewCompetitionCatalogLegacyMapper(h.db).
		Review(c.Request.Context(), packageID, mappingID, userID, request)
	if err != nil {
		h.respondCompetitionCatalogMappingError(c, err)
		return
	}
	h.writeCompetitionCatalogMappingAudit(packageID, userID, "catalog_mapping_review", request.ReviewStatus)
	c.JSON(http.StatusOK, mapping)
}

func (h *CompetitionHandler) AdminBatchConfirmCompetitionCatalogLegacyMappings(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	packageID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var request services.CompetitionCatalogLegacyMappingBatchConfirmRequest
	if !decodeStrictJSONRequest(c, &request) {
		return
	}
	confirmed, err := services.NewCompetitionCatalogLegacyMapper(h.db).
		BatchConfirm(c.Request.Context(), packageID, userID, request)
	if err != nil {
		h.respondCompetitionCatalogMappingError(c, err)
		return
	}
	h.writeCompetitionCatalogMappingAudit(packageID, userID, "catalog_mapping_batch_confirm", "success")
	c.JSON(http.StatusOK, gin.H{"confirmed": confirmed})
}

func (h *CompetitionHandler) AdminInheritCompetitionCatalogLegacyMappings(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	packageID, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var request services.CompetitionCatalogLegacyMappingInheritRequest
	if !decodeStrictJSONRequest(c, &request) {
		return
	}
	result, err := services.NewCompetitionCatalogLegacyMapper(h.db).
		Inherit(c.Request.Context(), packageID, userID, request)
	if err != nil {
		h.respondCompetitionCatalogMappingError(c, err)
		return
	}
	h.writeCompetitionCatalogMappingAudit(packageID, userID, "catalog_mapping_inherit", "success")
	c.JSON(http.StatusOK, result)
}

func (h *CompetitionHandler) respondCompetitionCatalogMappingError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(http.StatusNotFound, gin.H{"error": "目录包、映射或旧赛事不存在"})
	case errors.Is(err, services.ErrCatalogLegacyMappingInvalid):
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
	case errors.Is(err, services.ErrCatalogActivePackageRequired),
		errors.Is(err, services.ErrCatalogLegacyMappingConflict):
		c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"error": "旧赛事映射操作失败"})
	}
}

func (h *CompetitionHandler) writeCompetitionCatalogMappingAudit(
	packageID uint,
	userID uint,
	action string,
	result string,
) {
	_ = h.db.Create(&models.CompetitionCatalogAuditLog{
		PackageID: &packageID, ActorUserID: userID, Action: action, Result: result,
	}).Error
}

func (h *CompetitionHandler) AdminDiffCompetitionCatalogPackage(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var target models.CompetitionCatalogPackage
	if err := h.db.First(&target, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "目录包不存在"})
		return
	}
	var baseline models.CompetitionCatalogPackage
	if raw := c.Query("against_id"); raw != "" {
		againstID, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "against_id 无效"})
			return
		}
		if err := h.db.First(&baseline, uint(againstID)).Error; err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "对比目录包不存在"})
			return
		}
	} else if err := h.db.Where("is_active = ?", true).First(&baseline).Error; err != nil &&
		!errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取活动目录失败"})
		return
	}
	diff, err := competitionCatalogDiff(baseline.Payload, target.Payload)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "目录暂存数据损坏"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"against_package_id": baseline.ID, "target_package_id": target.ID,
		"added": diff.added, "removed": diff.removed, "changed": diff.changed,
	})
}

func (h *CompetitionHandler) AdminActivateCompetitionCatalog(c *gin.Context) {
	h.performCompetitionCatalogActivation(c, false)
}

func (h *CompetitionHandler) AdminPreflightCompetitionCatalog(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	result, err := services.NewCompetitionCatalogImporter(h.db).
		Preflight(c.Request.Context(), id, userID)
	if err != nil {
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			c.JSON(http.StatusNotFound, gin.H{"error": "目录包不存在"})
		case errors.Is(err, services.ErrCatalogPreflightFailed):
			c.JSON(http.StatusConflict, gin.H{
				"error": "目录激活预检未通过", "report": result.Report,
				"validation": result.Validation,
			})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "目录激活预检失败"})
		}
		return
	}
	c.JSON(http.StatusOK, result)
}

func (h *CompetitionHandler) AdminRollbackCompetitionCatalog(c *gin.Context) {
	h.performCompetitionCatalogActivation(c, true)
}

func (h *CompetitionHandler) performCompetitionCatalogActivation(c *gin.Context, rollback bool) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	importer := services.NewCompetitionCatalogImporter(h.db)
	var err error
	if rollback {
		err = importer.Rollback(c.Request.Context(), id, userID)
	} else {
		var request services.CompetitionCatalogActivationRequest
		if !decodeStrictJSONRequest(c, &request) {
			return
		}
		err = importer.ActivateWithPreflight(c.Request.Context(), id, userID, request)
	}
	if err != nil {
		if errors.Is(err, services.ErrCatalogNotActivatable) ||
			errors.Is(err, services.ErrCatalogPreflightRequired) {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "目录操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "目录操作成功"})
}

func decodeStrictJSONRequest(c *gin.Context, target any) bool {
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxCompetitionCatalogBytes)
	decoder := json.NewDecoder(c.Request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求 JSON 格式无效或包含未知字段"})
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体只能包含一个 JSON 对象"})
		return false
	}
	return true
}

func decodeCompetitionCatalogRequest(
	c *gin.Context,
) (dto.CompetitionCatalogDocument, bool) {
	var document dto.CompetitionCatalogDocument
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxCompetitionCatalogBytes)
	decoder := json.NewDecoder(c.Request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目录 JSON 格式无效或包含未知字段"})
		return document, false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体只能包含一个 JSON 对象"})
		return document, false
	}
	return document, true
}

type catalogDiffResult struct {
	added, removed, changed []string
}

func competitionCatalogDiff(
	baselinePayload, targetPayload []byte,
) (catalogDiffResult, error) {
	var baseline, target dto.CompetitionCatalogDocument
	if len(baselinePayload) > 0 {
		if err := json.Unmarshal(baselinePayload, &baseline); err != nil {
			return catalogDiffResult{}, err
		}
	}
	if err := json.Unmarshal(targetPayload, &target); err != nil {
		return catalogDiffResult{}, err
	}
	before := make(map[string]string, len(baseline.Items))
	after := make(map[string]string, len(target.Items))
	for _, item := range baseline.Items {
		before[item.CompetitionID] = item.RecordHash
	}
	for _, item := range target.Items {
		after[item.CompetitionID] = item.RecordHash
	}
	result := catalogDiffResult{added: []string{}, removed: []string{}, changed: []string{}}
	for id, hash := range after {
		previous, exists := before[id]
		if !exists {
			result.added = append(result.added, id)
		} else if previous != hash {
			result.changed = append(result.changed, id)
		}
	}
	for id := range before {
		if _, exists := after[id]; !exists {
			result.removed = append(result.removed, id)
		}
	}
	sort.Strings(result.added)
	sort.Strings(result.removed)
	sort.Strings(result.changed)
	return result, nil
}
