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

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

const (
	LegacyCompetitionBaselineDataset  = "legacy-production-baseline"
	legacyCompetitionBaselineFilename = "legacy-production-baseline.json"
)

var (
	ErrCatalogBaselineAlreadyExists = errors.New("competition catalog active package already exists")
	ErrCatalogBaselineEmpty         = errors.New("competition catalog legacy baseline is empty")
)

// CompetitionCatalogBaselineExporter 将首次切换前的公开旧赛事导出为保守基线包。
// 导出过程只读数据库，不暂存、不激活，也不修改旧赛事 ID。
type CompetitionCatalogBaselineExporter struct {
	db        *gorm.DB
	validator *CompetitionCatalogValidator
}

func NewCompetitionCatalogBaselineExporter(db *gorm.DB) *CompetitionCatalogBaselineExporter {
	return &CompetitionCatalogBaselineExporter{
		db: db, validator: NewCompetitionCatalogValidator(),
	}
}

func (e *CompetitionCatalogBaselineExporter) Export(
	ctx context.Context,
) (dto.CompetitionCatalogDocument, dto.CompetitionCatalogValidationResult, error) {
	var activeCount int64
	if err := e.db.WithContext(ctx).Model(&models.CompetitionCatalogPackage{}).
		Where("is_active = ?", true).Count(&activeCount).Error; err != nil {
		return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{}, err
	}
	if activeCount > 0 {
		return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{},
			ErrCatalogBaselineAlreadyExists
	}

	var events []models.CompetitionEvent
	if err := e.db.WithContext(ctx).
		Preload("PrimaryCategory").
		Where("competition_events.catalog_package_id IS NULL").
		Where("competition_events.dataset_version = '' OR competition_events.dataset_version = 'legacy'").
		Where("competition_events.status = ?", "published").
		Order("competition_events.id ASC").Find(&events).Error; err != nil {
		return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{}, err
	}
	if len(events) == 0 {
		return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{},
			ErrCatalogBaselineEmpty
	}

	document := dto.CompetitionCatalogDocument{
		SchemaVersion:  dto.CompetitionCatalogSchemaVersion,
		DatasetVersion: LegacyCompetitionBaselineDataset,
		PublishStatus:  "published", ProductionLoadAllowed: true,
		ItemCount: len(events), SourceFilename: legacyCompetitionBaselineFilename,
		Items: make([]dto.CompetitionCatalogRecord, 0, len(events)),
	}
	hashes := make(map[string]string, len(events))
	for index := range events {
		record, err := legacyEventToCatalogRecord(events[index], index+1)
		if err != nil {
			return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{}, err
		}
		recordHash, err := ComputeCompetitionRecordHash(record)
		if err != nil {
			return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{}, err
		}
		record.RecordHash = recordHash
		hashes[record.CompetitionID] = recordHash
		document.Items = append(document.Items, record)
	}
	packageHash, err := ComputeCompetitionPackageHash(document, hashes)
	if err != nil {
		return dto.CompetitionCatalogDocument{}, dto.CompetitionCatalogValidationResult{}, err
	}
	document.PackageHash = packageHash
	validation := e.validator.Validate(document)
	if validation.Status != "passed" {
		return document, validation, fmt.Errorf(
			"%w: 服务端生成的旧目录基线未通过校验",
			ErrCatalogValidationFailed,
		)
	}
	return document, validation, nil
}

func legacyEventToCatalogRecord(
	event models.CompetitionEvent,
	fallbackOrder int,
) (dto.CompetitionCatalogRecord, error) {
	competitionID := strings.TrimSpace(event.CompetitionID)
	if competitionID == "" {
		return dto.CompetitionCatalogRecord{}, fmt.Errorf("旧赛事 %d 缺少稳定 competition_id", event.ID)
	}
	decode := func(field string, raw datatypes.JSON) ([]string, error) {
		if len(raw) == 0 || string(raw) == "null" {
			return []string{}, nil
		}
		var values []string
		if err := json.Unmarshal(raw, &values); err != nil {
			return nil, fmt.Errorf("旧赛事 %s 的 %s 不是字符串数组: %w", competitionID, field, err)
		}
		return values, nil
	}
	tags, err := decode("tags", event.Tags)
	if err != nil {
		return dto.CompetitionCatalogRecord{}, err
	}
	entryYears, err := decode("eligible_entry_years", event.EligibleEntryYears)
	if err != nil {
		return dto.CompetitionCatalogRecord{}, err
	}
	colleges, err := decode("eligible_colleges", event.EligibleColleges)
	if err != nil {
		return dto.CompetitionCatalogRecord{}, err
	}
	majors, err := decode("eligible_majors", event.EligibleMajors)
	if err != nil {
		return dto.CompetitionCatalogRecord{}, err
	}
	riskTags, err := decode("risk_tags", event.RiskTags)
	if err != nil {
		return dto.CompetitionCatalogRecord{}, err
	}
	blockerCodes, err := decode("blocker_codes", event.BlockerCodes)
	if err != nil {
		return dto.CompetitionCatalogRecord{}, err
	}

	catalogOrder := event.CatalogOrder
	if catalogOrder <= 0 {
		catalogOrder = fallbackOrder
	}
	categorySlug := ""
	if event.PrimaryCategory != nil {
		categorySlug = event.PrimaryCategory.Slug
	}
	competitionRating := strings.TrimSpace(event.CompetitionRating)
	if competitionRating == "" {
		competitionRating = strings.TrimSpace(event.RecommendationLevel)
	}
	timePrecision := strings.TrimSpace(event.TimePrecision)
	if timePrecision == "" {
		timePrecision = "unknown"
	}
	timeStatus := strings.TrimSpace(event.TimeStatus)
	if timeStatus == "" {
		timeStatus = "pending"
	}

	return dto.CompetitionCatalogRecord{
		CompetitionID: competitionID, ParentCompetitionID: event.ParentCompetitionID,
		CatalogOrder: catalogOrder, Title: event.Title, Subtitle: event.Subtitle,
		Summary: event.Summary, Description: event.Description,
		PrimaryCategorySlug: categorySlug, Tags: tags,
		CompetitionLevel:        event.CompetitionLevel,
		SchoolRecognitionStatus: event.SchoolRecognitionStatus,
		SchoolRecognitionGrade:  event.SchoolRecognitionGrade,
		CompetitionRating:       competitionRating, ImportanceScore: event.ImportanceScore,
		Organizer: event.Organizer, HostUnit: event.HostUnit, TargetAudience: event.TargetAudience,
		EligibleEntryYears: entryYears, EligibleColleges: colleges, EligibleMajors: majors,
		ParticipationType: event.ParticipationType,
		TeamSizeMin:       event.TeamSizeMin, TeamSizeMax: event.TeamSizeMax,
		RegistrationStart: catalogTime(event.RegistrationStart),
		RegistrationEnd:   catalogTime(event.RegistrationEnd),
		EventStart:        catalogTime(event.EventStart), EventEnd: catalogTime(event.EventEnd),
		RegistrationTimeText: event.RegistrationTimeText, EventTimeText: event.EventTimeText,
		TimePrecision: timePrecision, TimeStatus: timeStatus, TimeNote: event.TimeNote,
		SortMonth: event.SortMonth, Location: event.Location, IsOnline: event.IsOnline,
		OfficialURL: event.OfficialURL, NoticeURL: event.NoticeURL,
		SourceChannel: event.SourceChannel, SourceNote: event.SourceNote,
		Status: "published", ManualRatingReasonPublic: event.ManualRatingReasonPublic,
		MajorFitSummaryPublic: event.MajorFitSummaryPublic,
		EvidenceSummaryPublic: event.EvidenceSummaryPublic,
		EvidenceSubgrade:      event.EvidenceSubgrade, RiskTags: riskTags,
		SearchDisplayAllowed: true, CandidatePoolAllowed: true,
		PersonalizedRankingAllowed: false, StrongRecommendationEligible: false,
		RecommendationPermissionLevel: "low", AIMode: "disabled",
		BlockerCodes: blockerCodes,
	}, nil
}

func catalogTime(value *time.Time) string {
	if value == nil {
		return ""
	}
	return value.UTC().Format(time.RFC3339)
}
