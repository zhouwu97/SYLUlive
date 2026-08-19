package services

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

const competitionCatalogPreflightTTL = 10 * time.Minute

var (
	ErrCatalogPreflightFailed   = errors.New("competition catalog preflight failed")
	ErrCatalogPreflightRequired = errors.New("competition catalog preflight token is required or stale")
)

type CompetitionCatalogPreflightReport struct {
	PackageID                          uint     `json:"package_id"`
	PackageHash                        string   `json:"package_hash"`
	ExpectedActivePackageID            *uint    `json:"expected_active_package_id"`
	DatasetVersion                     string   `json:"dataset_version"`
	ItemCount                          int      `json:"item_count"`
	PublicItemCount                    int      `json:"public_item_count"`
	CandidateItemCount                 int      `json:"candidate_item_count"`
	MissingCategories                  []string `json:"missing_categories"`
	MappingConflictCount               int      `json:"mapping_conflict_count"`
	MissingLegacyEventCount            int      `json:"missing_legacy_event_count"`
	CalendarReferenceCount             int64    `json:"calendar_reference_count"`
	AwardReferenceCount                int64    `json:"award_reference_count"`
	UnmappedReferencedLegacyEventCount int64    `json:"unmapped_referenced_legacy_event_count"`
	UnmappedCalendarReferenceCount     int64    `json:"unmapped_calendar_reference_count"`
	UnmappedAwardReferenceCount        int64    `json:"unmapped_award_reference_count"`
	DependencyHash                     string   `json:"dependency_hash"`
	BlockingIssues                     []string `json:"blocking_issues"`
	CanActivate                        bool     `json:"can_activate"`
}

type CompetitionCatalogPreflightResult struct {
	Token      string                                 `json:"preflight_token"`
	ExpiresAt  time.Time                              `json:"expires_at"`
	Report     CompetitionCatalogPreflightReport      `json:"report"`
	Validation dto.CompetitionCatalogValidationResult `json:"validation"`
}

type CompetitionCatalogActivationRequest struct {
	PreflightToken          string `json:"preflight_token"`
	ExpectedActivePackageID *uint  `json:"expected_active_package_id"`
	ExpectedPackageHash     string `json:"expected_package_hash"`
}

func (i *CompetitionCatalogImporter) Preflight(
	ctx context.Context,
	packageID uint,
	actorUserID uint,
) (CompetitionCatalogPreflightResult, error) {
	result := CompetitionCatalogPreflightResult{}
	err := i.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var catalog models.CompetitionCatalogPackage
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&catalog, packageID).Error; err != nil {
			return err
		}
		var document dto.CompetitionCatalogDocument
		if err := json.Unmarshal(catalog.Payload, &document); err != nil {
			return fmt.Errorf("%w: 暂存目录损坏", ErrCatalogPreflightFailed)
		}
		result.Validation = i.validator.Validate(document)
		report, err := i.buildPreflightReport(tx, catalog, document, result.Validation)
		if err != nil {
			return err
		}
		result.Report = report
		if !report.CanActivate {
			return ErrCatalogPreflightFailed
		}

		tokenBytes := make([]byte, 32)
		if _, err := rand.Read(tokenBytes); err != nil {
			return fmt.Errorf("生成目录预检 token 失败: %w", err)
		}
		result.Token = hex.EncodeToString(tokenBytes)
		tokenHash := sha256.Sum256([]byte(result.Token))
		now := i.now()
		result.ExpiresAt = now.Add(competitionCatalogPreflightTTL)
		reportJSON, err := json.Marshal(report)
		if err != nil {
			return err
		}
		if err := tx.Model(&models.CompetitionCatalogActivationSnapshot{}).
			Where("package_id = ? AND status = ?", packageID, "ready").
			Update("status", "superseded").Error; err != nil {
			return err
		}
		snapshot := models.CompetitionCatalogActivationSnapshot{
			PackageID: packageID, PackageHash: catalog.PackageHash,
			ExpectedActivePackageID: report.ExpectedActivePackageID,
			TokenHash:               hex.EncodeToString(tokenHash[:]), Report: datatypes.JSON(reportJSON),
			Status: "ready", CreatedBy: actorUserID, CreatedAt: now,
			ExpiresAt: result.ExpiresAt,
		}
		return tx.Create(&snapshot).Error
	})
	return result, err
}

func (i *CompetitionCatalogImporter) buildPreflightReport(
	tx *gorm.DB,
	catalog models.CompetitionCatalogPackage,
	document dto.CompetitionCatalogDocument,
	validation dto.CompetitionCatalogValidationResult,
) (CompetitionCatalogPreflightReport, error) {
	report := CompetitionCatalogPreflightReport{
		PackageID: catalog.ID, PackageHash: catalog.PackageHash,
		DatasetVersion: catalog.DatasetVersion, ItemCount: len(document.Items),
		MissingCategories: []string{}, BlockingIssues: []string{},
	}
	dependencyParts := make([]string, 0)
	var active models.CompetitionCatalogPackage
	activeErr := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("is_active = ?", true).First(&active).Error
	if activeErr == nil {
		report.ExpectedActivePackageID = &active.ID
		dependencyParts = append(dependencyParts, fmt.Sprintf("active:%d", active.ID))
	} else if !errors.Is(activeErr, gorm.ErrRecordNotFound) {
		return report, activeErr
	} else {
		dependencyParts = append(dependencyParts, "active:none")
	}

	addBlocker := func(code string) {
		for _, existing := range report.BlockingIssues {
			if existing == code {
				return
			}
		}
		report.BlockingIssues = append(report.BlockingIssues, code)
	}
	if catalog.PublishStatus != "published" || !catalog.ProductionLoadAllowed ||
		catalog.ValidationStatus != "passed" {
		addBlocker("package_not_activatable")
	}
	if validation.Status != "passed" || validation.ComputedPackageHash != catalog.PackageHash {
		addBlocker("package_hash_or_validation_changed")
	}
	if report.ExpectedActivePackageID == nil && !isLegacyCompetitionBaseline(catalog.DatasetVersion) {
		addBlocker("legacy_baseline_required_before_first_activation")
	}

	categorySet := make(map[string]struct{})
	for _, record := range document.Items {
		if record.Status == "published" && record.SearchDisplayAllowed {
			report.PublicItemCount++
			if record.CandidatePoolAllowed {
				report.CandidateItemCount++
			}
		}
		if slug := strings.TrimSpace(record.PrimaryCategorySlug); slug != "" {
			categorySet[slug] = struct{}{}
		}
	}
	if len(categorySet) > 0 {
		slugs := make([]string, 0, len(categorySet))
		for slug := range categorySet {
			slugs = append(slugs, slug)
		}
		sort.Strings(slugs)
		var found []string
		if err := tx.Model(&models.CompetitionCategory{}).
			Where("slug IN ? AND is_active = ?", slugs, true).Pluck("slug", &found).Error; err != nil {
			return report, err
		}
		foundSet := make(map[string]struct{}, len(found))
		for _, slug := range found {
			foundSet[slug] = struct{}{}
		}
		for _, slug := range slugs {
			if _, exists := foundSet[slug]; !exists {
				report.MissingCategories = append(report.MissingCategories, slug)
				dependencyParts = append(dependencyParts, "category-missing:"+slug)
			} else {
				dependencyParts = append(dependencyParts, "category:"+slug)
			}
		}
		sort.Strings(report.MissingCategories)
		if len(report.MissingCategories) > 0 {
			addBlocker("missing_categories")
		}
	}

	confirmedMappedEventIDs := make(map[uint]struct{})
	if tx.Migrator().HasTable(&models.CompetitionCatalogLegacyMapping{}) {
		type conflictRow struct {
			LegacyEventID uint
			Count         int64
		}
		var conflicts []conflictRow
		if err := tx.Model(&models.CompetitionCatalogLegacyMapping{}).
			Select("legacy_event_id, COUNT(*) AS count").
			Where("package_id = ? AND review_status = ?", catalog.ID, "confirmed").
			Group("legacy_event_id").Having("COUNT(*) > 1").Scan(&conflicts).Error; err != nil {
			return report, err
		}
		report.MappingConflictCount = len(conflicts)
		if report.MappingConflictCount > 0 {
			addBlocker("confirmed_mapping_conflicts")
		}
		var mappings []models.CompetitionCatalogLegacyMapping
		if err := tx.Where("package_id = ? AND review_status = ?", catalog.ID, "confirmed").
			Order("competition_id ASC, legacy_event_id ASC").Find(&mappings).Error; err != nil {
			return report, err
		}
		mappedEventIDs := make([]uint, 0, len(mappings))
		for _, mapping := range mappings {
			mappedEventIDs = append(mappedEventIDs, mapping.LegacyEventID)
			confirmedMappedEventIDs[mapping.LegacyEventID] = struct{}{}
		}
		if len(mappedEventIDs) > 0 {
			var existingEventIDs []uint
			if err := tx.Model(&models.CompetitionEvent{}).Where("id IN ?", mappedEventIDs).
				Pluck("id", &existingEventIDs).Error; err != nil {
				return report, err
			}
			existingSet := make(map[uint]struct{}, len(existingEventIDs))
			for _, eventID := range existingEventIDs {
				existingSet[eventID] = struct{}{}
			}
			for _, mapping := range mappings {
				_, exists := existingSet[mapping.LegacyEventID]
				dependencyParts = append(dependencyParts, fmt.Sprintf(
					"mapping:%s:%d:%t", mapping.CompetitionID, mapping.LegacyEventID, exists,
				))
				if !exists {
					report.MissingLegacyEventCount++
				}
			}
			if report.MissingLegacyEventCount > 0 {
				addBlocker("confirmed_mapping_event_missing")
			}
			if tx.Migrator().HasTable(&models.UserCompetitionCalendarItem{}) {
				if err := tx.Model(&models.UserCompetitionCalendarItem{}).
					Where("source_event_id IN ?", mappedEventIDs).
					Count(&report.CalendarReferenceCount).Error; err != nil {
					return report, err
				}
			}
			if tx.Migrator().HasTable(&models.UserCompetitionAward{}) {
				if err := tx.Model(&models.UserCompetitionAward{}).
					Where("competition_event_id IN ?", mappedEventIDs).
					Count(&report.AwardReferenceCount).Error; err != nil {
					return report, err
				}
			}
		}
	}
	if report.ExpectedActivePackageID != nil && *report.ExpectedActivePackageID != catalog.ID {
		var activeEventIDs []uint
		if err := tx.Model(&models.CompetitionEvent{}).
			Where("catalog_package_id = ?", *report.ExpectedActivePackageID).
			Order("id ASC").Pluck("id", &activeEventIDs).Error; err != nil {
			return report, err
		}
		unmappedEventIDs := make([]uint, 0, len(activeEventIDs))
		for _, eventID := range activeEventIDs {
			if _, mapped := confirmedMappedEventIDs[eventID]; !mapped {
				unmappedEventIDs = append(unmappedEventIDs, eventID)
			}
		}
		calendarCounts := make(map[uint]int64)
		awardCounts := make(map[uint]int64)
		if len(unmappedEventIDs) > 0 && tx.Migrator().HasTable(&models.UserCompetitionCalendarItem{}) {
			if err := scanReferenceCounts(tx, (&models.UserCompetitionCalendarItem{}).TableName(),
				"source_event_id", unmappedEventIDs, calendarCounts); err != nil {
				return report, err
			}
		}
		if len(unmappedEventIDs) > 0 && tx.Migrator().HasTable(&models.UserCompetitionAward{}) {
			if err := scanReferenceCounts(tx, (&models.UserCompetitionAward{}).TableName(),
				"competition_event_id", unmappedEventIDs, awardCounts); err != nil {
				return report, err
			}
		}
		for _, eventID := range unmappedEventIDs {
			calendarCount := calendarCounts[eventID]
			awardCount := awardCounts[eventID]
			report.UnmappedCalendarReferenceCount += calendarCount
			report.UnmappedAwardReferenceCount += awardCount
			if calendarCount > 0 || awardCount > 0 {
				report.UnmappedReferencedLegacyEventCount++
			}
			dependencyParts = append(dependencyParts, fmt.Sprintf(
				"unmapped-reference:%d:%d:%d", eventID, calendarCount, awardCount,
			))
		}
		if report.UnmappedReferencedLegacyEventCount > 0 {
			addBlocker("unmapped_referenced_legacy_events")
		}
	}
	if report.ExpectedActivePackageID == nil && isLegacyCompetitionBaseline(catalog.DatasetVersion) {
		matches, fingerprint, err := legacyBaselineMatchesCurrent(tx, document)
		if err != nil {
			return report, err
		}
		dependencyParts = append(dependencyParts, "legacy-baseline:"+fingerprint)
		if !matches {
			addBlocker("legacy_baseline_snapshot_changed")
		}
	}
	sort.Strings(dependencyParts)
	dependencyDigest := sha256.Sum256([]byte(strings.Join(dependencyParts, "\n")))
	report.DependencyHash = hex.EncodeToString(dependencyDigest[:])
	sort.Strings(report.BlockingIssues)
	report.CanActivate = len(report.BlockingIssues) == 0
	return report, nil
}

func (i *CompetitionCatalogImporter) ActivateWithPreflight(
	ctx context.Context,
	packageID uint,
	actorUserID uint,
	request CompetitionCatalogActivationRequest,
) error {
	request.PreflightToken = strings.TrimSpace(request.PreflightToken)
	request.ExpectedPackageHash = strings.TrimSpace(request.ExpectedPackageHash)
	if request.PreflightToken == "" || request.ExpectedPackageHash == "" {
		return ErrCatalogPreflightRequired
	}
	err := i.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var catalog models.CompetitionCatalogPackage
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&catalog, packageID).Error; err != nil {
			return err
		}
		tokenHash := sha256.Sum256([]byte(request.PreflightToken))
		var snapshot models.CompetitionCatalogActivationSnapshot
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where(
			"package_id = ? AND token_hash = ? AND status = ?",
			packageID, hex.EncodeToString(tokenHash[:]), "ready",
		).First(&snapshot).Error; err != nil {
			return ErrCatalogPreflightRequired
		}
		now := i.now()
		if !snapshot.ExpiresAt.After(now) || snapshot.CreatedBy != actorUserID ||
			snapshot.PackageHash != catalog.PackageHash ||
			request.ExpectedPackageHash != catalog.PackageHash {
			return ErrCatalogPreflightRequired
		}
		var document dto.CompetitionCatalogDocument
		if err := json.Unmarshal(catalog.Payload, &document); err != nil {
			return ErrCatalogPreflightRequired
		}
		validation := i.validator.Validate(document)
		currentReport, err := i.buildPreflightReport(tx, catalog, document, validation)
		if err != nil {
			return err
		}
		var snapshotReport CompetitionCatalogPreflightReport
		if err := json.Unmarshal(snapshot.Report, &snapshotReport); err != nil {
			return ErrCatalogPreflightRequired
		}
		if !currentReport.CanActivate || currentReport.DependencyHash != snapshotReport.DependencyHash ||
			!sameOptionalCatalogPackageID(currentReport.ExpectedActivePackageID, snapshot.ExpectedActivePackageID) ||
			!sameOptionalCatalogPackageID(currentReport.ExpectedActivePackageID, request.ExpectedActivePackageID) {
			return ErrCatalogPreflightRequired
		}
		if err := i.activatePackageTx(tx, &catalog, actorUserID, "catalog_activate"); err != nil {
			return err
		}
		return tx.Model(&snapshot).Updates(map[string]any{
			"status": "consumed", "consumed_at": now,
		}).Error
	})
	if err != nil {
		i.writeAudit(ctx, &packageID, actorUserID, "catalog_activate", "rejected", err.Error())
	}
	return err
}

func legacyBaselineMatchesCurrent(
	tx *gorm.DB,
	document dto.CompetitionCatalogDocument,
) (bool, string, error) {
	var events []models.CompetitionEvent
	query := tx.Preload("PrimaryCategory").
		Where("competition_events.catalog_package_id IS NULL").
		Where("competition_events.dataset_version = '' OR competition_events.dataset_version = 'legacy'")
	identityBaseline := document.DatasetVersion == LegacyCompetitionIdentityBaselineDataset
	if identityBaseline {
		canonicalIDs := tx.Model(&models.CompetitionLegacyDuplicateResolution{}).
			Distinct("canonical_event_id").Select("canonical_event_id")
		query = query.Unscoped().Where("competition_events.id IN (?)", canonicalIDs)
	} else {
		query = query.Where("competition_events.status = ?", "published")
	}
	if err := query.Order("competition_events.id ASC").Find(&events).Error; err != nil {
		return false, "", err
	}
	expected := make(map[string]string, len(document.Items))
	for _, item := range document.Items {
		expected[item.CompetitionID] = item.RecordHash
	}
	parts := make([]string, 0, len(events))
	matches := len(events) == len(document.Items)
	for index := range events {
		record, err := legacyEventToCatalogRecord(events[index], index+1)
		if err != nil {
			return false, "", err
		}
		if identityBaseline {
			record.Status = events[index].Status
			record.SearchDisplayAllowed = false
			record.CandidatePoolAllowed = false
			record.PersonalizedRankingAllowed = false
			record.StrongRecommendationEligible = false
			record.RecommendationPermissionLevel = "blocked"
			record.AIMode = "disabled"
		}
		recordHash, err := ComputeCompetitionRecordHash(record)
		if err != nil {
			return false, "", err
		}
		parts = append(parts, record.CompetitionID+":"+recordHash)
		if expected[record.CompetitionID] != recordHash {
			matches = false
		}
	}
	sort.Strings(parts)
	digest := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return matches, hex.EncodeToString(digest[:]), nil
}

func isLegacyCompetitionBaseline(datasetVersion string) bool {
	return datasetVersion == LegacyCompetitionBaselineDataset ||
		datasetVersion == LegacyCompetitionIdentityBaselineDataset
}

func lockedActiveCatalogPackageID(tx *gorm.DB) (*uint, error) {
	var active models.CompetitionCatalogPackage
	err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("is_active = ?", true).First(&active).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &active.ID, nil
}

func sameOptionalCatalogPackageID(left, right *uint) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}
