package services

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

var (
	ErrCatalogValidationFailed = errors.New("competition catalog validation failed")
	ErrCatalogNotActivatable   = errors.New("competition catalog is not activatable")
)

type CompetitionCatalogImporter struct {
	db        *gorm.DB
	validator *CompetitionCatalogValidator
	now       func() time.Time
}

func NewCompetitionCatalogImporter(db *gorm.DB) *CompetitionCatalogImporter {
	return &CompetitionCatalogImporter{
		db: db, validator: NewCompetitionCatalogValidator(), now: time.Now,
	}
}

func (i *CompetitionCatalogImporter) Validate(
	document dto.CompetitionCatalogDocument,
) dto.CompetitionCatalogValidationResult {
	return i.validator.Validate(document)
}

func (i *CompetitionCatalogImporter) Import(
	ctx context.Context,
	document dto.CompetitionCatalogDocument,
	actorUserID uint,
) (models.CompetitionCatalogPackage, dto.CompetitionCatalogValidationResult, error) {
	validation := i.validator.Validate(document)
	validationJSON, _ := json.Marshal(validation)
	if validation.Status != "passed" {
		i.writeAudit(ctx, nil, actorUserID, "catalog_import", "rejected", "目录校验未通过")
		return models.CompetitionCatalogPackage{}, validation, ErrCatalogValidationFailed
	}
	payload, err := json.Marshal(document)
	if err != nil {
		return models.CompetitionCatalogPackage{}, validation, fmt.Errorf("编码目录包失败: %w", err)
	}
	var catalog models.CompetitionCatalogPackage
	if err := i.db.WithContext(ctx).Where("package_hash = ?", document.PackageHash).First(&catalog).Error; err == nil {
		i.writeAudit(ctx, &catalog.ID, actorUserID, "catalog_import", "idempotent", catalog.DatasetVersion)
		return catalog, validation, nil
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return models.CompetitionCatalogPackage{}, validation, err
	}
	now := i.now()
	err = i.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var maximumRevision int
		if err := tx.Model(&models.CompetitionCatalogPackage{}).
			Where("dataset_version = ?", document.DatasetVersion).
			Select("COALESCE(MAX(revision), 0)").Scan(&maximumRevision).Error; err != nil {
			return err
		}
		catalog = models.CompetitionCatalogPackage{
			SchemaVersion: document.SchemaVersion, DatasetVersion: document.DatasetVersion,
			Revision: maximumRevision + 1, PackageHash: document.PackageHash,
			LifecycleStatus: "staged", PublishStatus: document.PublishStatus,
			ProductionLoadAllowed: document.ProductionLoadAllowed, ItemCount: document.ItemCount,
			ValidationStatus: validation.Status, ValidationResult: datatypes.JSON(validationJSON),
			Payload: datatypes.JSON(payload), SourceFilename: document.SourceFilename,
			ImportedBy: actorUserID, ImportedAt: now,
		}
		return tx.Create(&catalog).Error
	})
	if err != nil {
		var existing models.CompetitionCatalogPackage
		if findErr := i.db.WithContext(ctx).Where("package_hash = ?", document.PackageHash).First(&existing).Error; findErr == nil {
			i.writeAudit(ctx, &existing.ID, actorUserID, "catalog_import", "idempotent", existing.DatasetVersion)
			return existing, validation, nil
		}
		i.writeAudit(ctx, nil, actorUserID, "catalog_import", "failed", "目录暂存失败")
		return models.CompetitionCatalogPackage{}, validation, err
	}
	i.writeAudit(ctx, &catalog.ID, actorUserID, "catalog_import", "success", catalog.DatasetVersion)
	return catalog, validation, nil
}

func (i *CompetitionCatalogImporter) Activate(
	ctx context.Context,
	packageID uint,
	actorUserID uint,
) error {
	err := i.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var catalog models.CompetitionCatalogPackage
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&catalog, packageID).Error; err != nil {
			return err
		}
		if err := i.activatePackageTx(tx, &catalog, actorUserID, "catalog_activate"); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		i.writeAudit(ctx, &packageID, actorUserID, "catalog_activate", "rejected", err.Error())
	}
	return err
}

func (i *CompetitionCatalogImporter) Rollback(
	ctx context.Context,
	currentPackageID uint,
	actorUserID uint,
) error {
	err := i.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var current models.CompetitionCatalogPackage
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&current, currentPackageID).Error; err != nil {
			return err
		}
		if !current.IsActive || current.PreviousPackageID == nil {
			return fmt.Errorf("%w: 当前包不是活动包或没有上一版本", ErrCatalogNotActivatable)
		}
		var previous models.CompetitionCatalogPackage
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&previous, *current.PreviousPackageID).Error; err != nil {
			return err
		}
		if err := i.activatePackageTx(tx, &previous, actorUserID, "catalog_rollback"); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		i.writeAudit(ctx, &currentPackageID, actorUserID, "catalog_rollback", "rejected", err.Error())
	}
	return err
}

func (i *CompetitionCatalogImporter) activatePackageTx(
	tx *gorm.DB,
	catalog *models.CompetitionCatalogPackage,
	actorUserID uint,
	action string,
) error {
	if catalog.PublishStatus != "published" || !catalog.ProductionLoadAllowed ||
		catalog.ValidationStatus != "passed" {
		return fmt.Errorf("%w: 目录包未发布、未允许生产加载或校验未通过", ErrCatalogNotActivatable)
	}
	var document dto.CompetitionCatalogDocument
	if err := json.Unmarshal(catalog.Payload, &document); err != nil {
		return fmt.Errorf("%w: 暂存目录损坏", ErrCatalogNotActivatable)
	}
	validation := i.validator.Validate(document)
	if validation.Status != "passed" || validation.ComputedPackageHash != catalog.PackageHash {
		return fmt.Errorf("%w: 激活前复算摘要不一致", ErrCatalogNotActivatable)
	}
	var active models.CompetitionCatalogPackage
	activeErr := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("is_active = ?", true).First(&active).Error
	if activeErr != nil && !errors.Is(activeErr, gorm.ErrRecordNotFound) {
		return activeErr
	}

	now := i.now()
	activeIDs := make([]string, 0, len(document.Items))
	eventIDs := make(map[string]uint, len(document.Items))
	for _, record := range document.Items {
		event, err := i.eventFromCatalogRecord(tx, *catalog, record, now)
		if err != nil {
			return err
		}
		var existing models.CompetitionEvent
		err = tx.Where("competition_id = ?", event.CompetitionID).First(&existing).Error
		if errors.Is(err, gorm.ErrRecordNotFound) && tx.Migrator().HasTable(&models.CompetitionCatalogLegacyMapping{}) {
			var mapping models.CompetitionCatalogLegacyMapping
			mappingErr := tx.Where(
				"package_id = ? AND competition_id = ? AND review_status = ?",
				catalog.ID, event.CompetitionID, "confirmed",
			).First(&mapping).Error
			if mappingErr == nil {
				err = tx.First(&existing, mapping.LegacyEventID).Error
			} else if !errors.Is(mappingErr, gorm.ErrRecordNotFound) {
				return mappingErr
			}
		}
		if err == nil {
			if err := tx.Model(&models.CompetitionEvent{}).Where("id = ?", existing.ID).
				Updates(catalogEventUpdates(event)).Error; err != nil {
				return fmt.Errorf("更新赛事 %s 失败: %w", event.CompetitionID, err)
			}
			event.ID = existing.ID
		} else if errors.Is(err, gorm.ErrRecordNotFound) {
			if err := tx.Create(&event).Error; err != nil {
				return fmt.Errorf("创建赛事 %s 失败: %w", event.CompetitionID, err)
			}
		} else {
			return err
		}
		activeIDs = append(activeIDs, event.CompetitionID)
		eventIDs[event.CompetitionID] = event.ID
	}
	for _, record := range document.Items {
		competitionID := strings.TrimSpace(record.CompetitionID)
		parentCompetitionID := strings.TrimSpace(record.ParentCompetitionID)
		updates := map[string]any{"parent_competition_id": parentCompetitionID, "parent_event_id": nil}
		if parentCompetitionID != "" {
			parentEventID, exists := eventIDs[parentCompetitionID]
			if !exists {
				return fmt.Errorf("赛事 %s 的父赛事 %s 未落库", competitionID, parentCompetitionID)
			}
			updates["parent_event_id"] = parentEventID
		}
		if err := tx.Model(&models.CompetitionEvent{}).
			Where("id = ?", eventIDs[competitionID]).Updates(updates).Error; err != nil {
			return err
		}
	}
	archiveQuery := tx.Model(&models.CompetitionEvent{}).
		Where("catalog_package_id IS NOT NULL")
	if len(activeIDs) > 0 {
		archiveQuery = archiveQuery.Where("competition_id NOT IN ?", activeIDs)
	}
	if err := archiveQuery.Updates(map[string]any{
		"status": "archived", "search_display_allowed": false,
		"candidate_pool_allowed": false, "personalized_ranking_allowed": false,
		"strong_recommendation_eligible": false, "archived_at": now,
	}).Error; err != nil {
		return err
	}
	if activeErr == nil && active.ID != catalog.ID {
		if err := tx.Model(&active).Updates(map[string]any{
			"is_active": false, "lifecycle_status": "retired",
		}).Error; err != nil {
			return err
		}
		if action != "catalog_rollback" {
			catalog.PreviousPackageID = &active.ID
		}
	}
	if err := tx.Model(&models.CompetitionCatalogPackage{}).
		Where("id <> ?", catalog.ID).Update("is_active", false).Error; err != nil {
		return err
	}
	if err := tx.Model(catalog).Updates(map[string]any{
		"is_active": true, "activated_at": now, "previous_package_id": catalog.PreviousPackageID,
		"lifecycle_status": "active",
	}).Error; err != nil {
		return err
	}
	return tx.Create(&models.CompetitionCatalogAuditLog{
		PackageID: &catalog.ID, ActorUserID: actorUserID, Action: action,
		Result: "success", Detail: catalog.DatasetVersion, CreatedAt: now,
	}).Error
}

// catalogEventUpdates 只覆盖 Catalog 2.2 明确定义的治理字段。
// 旧赛事的附件、承办单位、来源文章和审核元数据不在目录契约中，激活时必须保留。
func catalogEventUpdates(event models.CompetitionEvent) map[string]any {
	return map[string]any{
		"competition_id": event.CompetitionID, "catalog_package_id": event.CatalogPackageID,
		"dataset_version": event.DatasetVersion, "record_hash": event.RecordHash,
		"catalog_order": event.CatalogOrder, "parent_competition_id": event.ParentCompetitionID,
		"title": event.Title, "subtitle": event.Subtitle, "summary": event.Summary,
		"description": event.Description, "primary_category_id": event.PrimaryCategoryID,
		"tags": event.Tags, "competition_level": event.CompetitionLevel,
		"school_recognition_status": event.SchoolRecognitionStatus,
		"school_recognition_grade":  event.SchoolRecognitionGrade,
		"competition_rating":        event.CompetitionRating,
		"recommendation_level":      event.RecommendationLevel,
		"importance_score":          event.ImportanceScore, "organizer": event.Organizer,
		"host_unit": event.HostUnit, "target_audience": event.TargetAudience,
		"eligible_entry_years": event.EligibleEntryYears,
		"eligible_colleges":    event.EligibleColleges, "eligible_majors": event.EligibleMajors,
		"participation_type": event.ParticipationType, "team_size_min": event.TeamSizeMin,
		"team_size_max": event.TeamSizeMax, "registration_start": event.RegistrationStart,
		"registration_end": event.RegistrationEnd, "event_start": event.EventStart,
		"event_end": event.EventEnd, "registration_time_text": event.RegistrationTimeText,
		"event_time_text": event.EventTimeText, "time_precision": event.TimePrecision,
		"time_status": event.TimeStatus, "time_note": event.TimeNote,
		"sort_month": event.SortMonth, "location": event.Location, "is_online": event.IsOnline,
		"official_url": event.OfficialURL, "notice_url": event.NoticeURL,
		"source_channel": event.SourceChannel, "source_note": event.SourceNote,
		"status": event.Status, "manual_rating_reason_public": event.ManualRatingReasonPublic,
		"major_fit_summary_public": event.MajorFitSummaryPublic,
		"evidence_summary_public":  event.EvidenceSummaryPublic,
		"evidence_subgrade":        event.EvidenceSubgrade, "risk_tags": event.RiskTags,
		"search_display_allowed":          event.SearchDisplayAllowed,
		"candidate_pool_allowed":          event.CandidatePoolAllowed,
		"personalized_ranking_allowed":    event.PersonalizedRankingAllowed,
		"strong_recommendation_eligible":  event.StrongRecommendationEligible,
		"recommendation_permission_level": event.RecommendationPermissionLevel,
		"ai_mode":                         event.AIMode, "blocker_codes": event.BlockerCodes,
		"version": event.Version, "updated_at": event.UpdatedAt, "archived_at": nil,
	}
}

func (i *CompetitionCatalogImporter) eventFromCatalogRecord(
	tx *gorm.DB,
	catalog models.CompetitionCatalogPackage,
	record dto.CompetitionCatalogRecord,
	now time.Time,
) (models.CompetitionEvent, error) {
	normalized, err := normalizeCatalogRecord(record)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	var category models.CompetitionCategory
	if normalized.PrimaryCategorySlug != "" {
		if err := tx.Where("slug = ? AND is_active = ?", normalized.PrimaryCategorySlug, true).
			First(&category).Error; err != nil {
			return models.CompetitionEvent{}, fmt.Errorf(
				"赛事 %s 的分类 %s 不存在或未启用",
				normalized.CompetitionID, normalized.PrimaryCategorySlug,
			)
		}
	}
	parse := func(value string) (*time.Time, error) {
		if value == "" {
			return nil, nil
		}
		for _, layout := range []string{"2006-01-02", time.RFC3339} {
			if parsed, parseErr := time.Parse(layout, value); parseErr == nil {
				return &parsed, nil
			}
		}
		return nil, fmt.Errorf("日期格式无效: %s", value)
	}
	registrationStart, err := parse(normalized.RegistrationStart)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	registrationEnd, err := parse(normalized.RegistrationEnd)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	eventStart, err := parse(normalized.EventStart)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	eventEnd, err := parse(normalized.EventEnd)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	jsonValue := func(value any) datatypes.JSON {
		encoded, _ := json.Marshal(value)
		return datatypes.JSON(encoded)
	}
	recordHash := normalized.RecordHash
	return models.CompetitionEvent{
		CompetitionID: normalized.CompetitionID, CatalogPackageID: &catalog.ID,
		DatasetVersion: catalog.DatasetVersion, RecordHash: recordHash,
		CatalogOrder: normalized.CatalogOrder, ParentCompetitionID: normalized.ParentCompetitionID,
		Title:    normalized.Title,
		Subtitle: normalized.Subtitle, Summary: normalized.Summary, Description: normalized.Description,
		PrimaryCategoryID: category.ID, Tags: jsonValue(normalized.Tags),
		CompetitionLevel:        normalized.CompetitionLevel,
		SchoolRecognitionStatus: normalized.SchoolRecognitionStatus,
		SchoolRecognitionGrade:  normalized.SchoolRecognitionGrade,
		CompetitionRating:       normalized.CompetitionRating, RecommendationLevel: normalized.CompetitionRating,
		ImportanceScore: normalized.ImportanceScore, Organizer: normalized.Organizer,
		HostUnit: normalized.HostUnit, TargetAudience: normalized.TargetAudience,
		EligibleEntryYears: jsonValue(normalized.EligibleEntryYears),
		EligibleColleges:   jsonValue(normalized.EligibleColleges),
		EligibleMajors:     jsonValue(normalized.EligibleMajors),
		ParticipationType:  normalized.ParticipationType,
		TeamSizeMin:        normalized.TeamSizeMin, TeamSizeMax: normalized.TeamSizeMax,
		RegistrationStart: registrationStart, RegistrationEnd: registrationEnd,
		EventStart: eventStart, EventEnd: eventEnd,
		RegistrationTimeText: normalized.RegistrationTimeText,
		EventTimeText:        normalized.EventTimeText, TimePrecision: normalized.TimePrecision,
		TimeStatus: normalized.TimeStatus, TimeNote: normalized.TimeNote,
		SortMonth: normalized.SortMonth, Location: normalized.Location, IsOnline: normalized.IsOnline,
		OfficialURL: normalized.OfficialURL, NoticeURL: normalized.NoticeURL,
		SourceChannel: normalized.SourceChannel, SourceNote: normalized.SourceNote,
		Status: normalized.Status, ManualRatingReasonPublic: normalized.ManualRatingReasonPublic,
		MajorFitSummaryPublic: normalized.MajorFitSummaryPublic,
		EvidenceSummaryPublic: normalized.EvidenceSummaryPublic,
		EvidenceSubgrade:      normalized.EvidenceSubgrade, RiskTags: jsonValue(normalized.RiskTags),
		SearchDisplayAllowed:          normalized.SearchDisplayAllowed,
		CandidatePoolAllowed:          normalized.CandidatePoolAllowed,
		PersonalizedRankingAllowed:    normalized.PersonalizedRankingAllowed,
		StrongRecommendationEligible:  normalized.StrongRecommendationEligible,
		RecommendationPermissionLevel: normalized.RecommendationPermissionLevel,
		AIMode:                        normalized.AIMode, BlockerCodes: jsonValue(normalized.BlockerCodes),
		Version: 1, UpdatedAt: now, ArchivedAt: nil,
	}, nil
}

func (i *CompetitionCatalogImporter) writeAudit(
	ctx context.Context,
	packageID *uint,
	actorUserID uint,
	action, result, detail string,
) {
	_ = i.db.WithContext(ctx).Create(&models.CompetitionCatalogAuditLog{
		PackageID: packageID, ActorUserID: actorUserID, Action: action,
		Result: result, Detail: truncateCatalogAuditDetail(detail), CreatedAt: i.now(),
	}).Error
}

func truncateCatalogAuditDetail(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 500 {
		return value[:500]
	}
	return value
}
