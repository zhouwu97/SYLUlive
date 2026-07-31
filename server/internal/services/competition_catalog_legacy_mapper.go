package services

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strings"
	"time"
	"unicode"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

var (
	ErrCatalogActivePackageRequired = errors.New("需要先激活旧目录基线包")
	ErrCatalogLegacyMappingInvalid  = errors.New("旧赛事映射无效")
	ErrCatalogLegacyMappingConflict = errors.New("旧赛事已被其他目录记录确认占用")
)

type CompetitionCatalogLegacyMapper struct {
	db  *gorm.DB
	now func() time.Time
}

type CompetitionCatalogLegacySuggestionResult struct {
	Created       int `json:"created"`
	Updated       int `json:"updated"`
	ConflictCount int `json:"conflict_count"`
	Unmatched     int `json:"unmatched"`
}

type CompetitionCatalogLegacyMappingItem struct {
	MappingID              *uint      `json:"mapping_id,omitempty"`
	PackageID              uint       `json:"package_id"`
	CompetitionID          string     `json:"competition_id"`
	CompetitionTitle       string     `json:"competition_title"`
	LegacyEventID          *uint      `json:"legacy_event_id,omitempty"`
	LegacyCompetitionID    string     `json:"legacy_competition_id,omitempty"`
	LegacyTitle            string     `json:"legacy_title,omitempty"`
	MatchType              string     `json:"match_type,omitempty"`
	Confidence             float64    `json:"confidence"`
	ReviewStatus           string     `json:"review_status"`
	CalendarReferenceCount int64      `json:"calendar_reference_count"`
	AwardReferenceCount    int64      `json:"award_reference_count"`
	ReviewedBy             *uint      `json:"reviewed_by,omitempty"`
	ReviewedAt             *time.Time `json:"reviewed_at,omitempty"`
}

type CompetitionCatalogLegacyMappingReviewRequest struct {
	LegacyEventID *uint  `json:"legacy_event_id,omitempty"`
	ReviewStatus  string `json:"review_status"`
}

type CompetitionCatalogLegacyMappingBatchConfirmRequest struct {
	MappingIDs []uint `json:"mapping_ids"`
}

func NewCompetitionCatalogLegacyMapper(db *gorm.DB) *CompetitionCatalogLegacyMapper {
	return &CompetitionCatalogLegacyMapper{db: db, now: time.Now}
}

func (m *CompetitionCatalogLegacyMapper) Suggest(
	ctx context.Context,
	packageID uint,
) (CompetitionCatalogLegacySuggestionResult, error) {
	result := CompetitionCatalogLegacySuggestionResult{}
	err := m.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		document, err := loadCatalogDocument(tx, packageID)
		if err != nil {
			return err
		}
		active, err := loadActiveCatalogPackage(tx)
		if err != nil {
			return err
		}
		if active.ID == packageID {
			return ErrCatalogLegacyMappingInvalid
		}

		var legacyEvents []models.CompetitionEvent
		if err := tx.Preload("PrimaryCategory").
			Where("catalog_package_id = ?", active.ID).
			Order("id ASC").Find(&legacyEvents).Error; err != nil {
			return err
		}
		if len(legacyEvents) == 0 {
			return ErrCatalogActivePackageRequired
		}

		var existing []models.CompetitionCatalogLegacyMapping
		if err := tx.Where("package_id = ?", packageID).Find(&existing).Error; err != nil {
			return err
		}
		existingByCompetition := make(map[string]models.CompetitionCatalogLegacyMapping, len(existing))
		confirmedOwner := make(map[uint]string)
		for _, mapping := range existing {
			existingByCompetition[mapping.CompetitionID] = mapping
			if mapping.ReviewStatus == "confirmed" {
				confirmedOwner[mapping.LegacyEventID] = mapping.CompetitionID
			}
		}

		type candidate struct {
			record    dto.CompetitionCatalogRecord
			event     models.CompetitionEvent
			typeID    string
			score     float64
			ambiguous bool
		}
		candidates := make([]candidate, 0, len(document.Items))
		owners := make(map[uint]int)
		for _, record := range document.Items {
			mapping, exists := existingByCompetition[record.CompetitionID]
			if exists && (mapping.ReviewStatus == "confirmed" || mapping.ReviewStatus == "rejected") {
				continue
			}
			event, matchType, score, ambiguous, ok := bestLegacyCandidate(record, legacyEvents)
			if !ok {
				result.Unmatched++
				continue
			}
			candidates = append(candidates, candidate{
				record: record, event: event, typeID: matchType, score: score, ambiguous: ambiguous,
			})
			owners[event.ID]++
		}

		for _, candidate := range candidates {
			status := "suggested"
			if candidate.ambiguous || owners[candidate.event.ID] > 1 ||
				(confirmedOwner[candidate.event.ID] != "" && confirmedOwner[candidate.event.ID] != candidate.record.CompetitionID) {
				status = "conflict"
				result.ConflictCount++
			}
			mapping, exists := existingByCompetition[candidate.record.CompetitionID]
			if !exists {
				mapping = models.CompetitionCatalogLegacyMapping{
					PackageID: packageID, CompetitionID: candidate.record.CompetitionID,
				}
			}
			mapping.LegacyEventID = candidate.event.ID
			mapping.MatchType = candidate.typeID
			mapping.Confidence = candidate.score
			mapping.ReviewStatus = status
			mapping.ReviewedBy = nil
			mapping.ReviewedAt = nil
			if exists {
				if err := tx.Save(&mapping).Error; err != nil {
					return err
				}
				result.Updated++
			} else {
				if err := tx.Create(&mapping).Error; err != nil {
					return err
				}
				result.Created++
			}
		}
		return supersedeCatalogPreflights(tx, packageID)
	})
	return result, err
}

func (m *CompetitionCatalogLegacyMapper) List(
	ctx context.Context,
	packageID uint,
) ([]CompetitionCatalogLegacyMappingItem, error) {
	document, err := loadCatalogDocument(m.db.WithContext(ctx), packageID)
	if err != nil {
		return nil, err
	}
	var mappings []models.CompetitionCatalogLegacyMapping
	if err := m.db.WithContext(ctx).Where("package_id = ?", packageID).
		Order("competition_id ASC").Find(&mappings).Error; err != nil {
		return nil, err
	}
	mappingByCompetition := make(map[string]models.CompetitionCatalogLegacyMapping, len(mappings))
	eventIDs := make([]uint, 0, len(mappings))
	for _, mapping := range mappings {
		mappingByCompetition[mapping.CompetitionID] = mapping
		eventIDs = append(eventIDs, mapping.LegacyEventID)
	}
	legacyByID := make(map[uint]models.CompetitionEvent, len(eventIDs))
	calendarCounts := make(map[uint]int64)
	awardCounts := make(map[uint]int64)
	if len(eventIDs) > 0 {
		var events []models.CompetitionEvent
		if err := m.db.WithContext(ctx).Where("id IN ?", eventIDs).Find(&events).Error; err != nil {
			return nil, err
		}
		for _, event := range events {
			legacyByID[event.ID] = event
		}
		if m.db.Migrator().HasTable(&models.UserCompetitionCalendarItem{}) {
			if err := scanReferenceCounts(m.db.WithContext(ctx),
				(&models.UserCompetitionCalendarItem{}).TableName(), "source_event_id", eventIDs, calendarCounts); err != nil {
				return nil, err
			}
		}
		if m.db.Migrator().HasTable(&models.UserCompetitionAward{}) {
			if err := scanReferenceCounts(m.db.WithContext(ctx),
				(&models.UserCompetitionAward{}).TableName(), "competition_event_id", eventIDs, awardCounts); err != nil {
				return nil, err
			}
		}
	}

	items := make([]CompetitionCatalogLegacyMappingItem, 0, len(document.Items))
	for _, record := range document.Items {
		item := CompetitionCatalogLegacyMappingItem{
			PackageID: packageID, CompetitionID: record.CompetitionID,
			CompetitionTitle: record.Title, ReviewStatus: "unmapped",
		}
		if mapping, exists := mappingByCompetition[record.CompetitionID]; exists {
			mappingID, legacyEventID := mapping.ID, mapping.LegacyEventID
			item.MappingID = &mappingID
			item.LegacyEventID = &legacyEventID
			item.MatchType = mapping.MatchType
			item.Confidence = mapping.Confidence
			item.ReviewStatus = mapping.ReviewStatus
			item.ReviewedBy = mapping.ReviewedBy
			item.ReviewedAt = mapping.ReviewedAt
			if event, found := legacyByID[mapping.LegacyEventID]; found {
				item.LegacyCompetitionID = event.CompetitionID
				item.LegacyTitle = event.Title
			}
			item.CalendarReferenceCount = calendarCounts[mapping.LegacyEventID]
			item.AwardReferenceCount = awardCounts[mapping.LegacyEventID]
		}
		items = append(items, item)
	}
	return items, nil
}

func (m *CompetitionCatalogLegacyMapper) Review(
	ctx context.Context,
	packageID uint,
	mappingID uint,
	actorUserID uint,
	request CompetitionCatalogLegacyMappingReviewRequest,
) (models.CompetitionCatalogLegacyMapping, error) {
	var result models.CompetitionCatalogLegacyMapping
	request.ReviewStatus = strings.TrimSpace(request.ReviewStatus)
	if request.ReviewStatus != "confirmed" && request.ReviewStatus != "rejected" {
		return result, ErrCatalogLegacyMappingInvalid
	}
	err := m.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if _, err := loadCatalogDocument(tx, packageID); err != nil {
			return err
		}
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("id = ? AND package_id = ?", mappingID, packageID).First(&result).Error; err != nil {
			return err
		}
		if request.LegacyEventID != nil {
			result.LegacyEventID = *request.LegacyEventID
			result.MatchType = "manual"
		}
		if request.ReviewStatus == "confirmed" {
			if err := validateConfirmedLegacyMapping(tx, result); err != nil {
				return err
			}
		}
		now := m.now()
		result.ReviewStatus = request.ReviewStatus
		result.ReviewedBy = &actorUserID
		result.ReviewedAt = &now
		if err := tx.Save(&result).Error; err != nil {
			return err
		}
		return supersedeCatalogPreflights(tx, packageID)
	})
	return result, err
}

func (m *CompetitionCatalogLegacyMapper) BatchConfirm(
	ctx context.Context,
	packageID uint,
	actorUserID uint,
	request CompetitionCatalogLegacyMappingBatchConfirmRequest,
) (int, error) {
	if len(request.MappingIDs) == 0 {
		return 0, ErrCatalogLegacyMappingInvalid
	}
	uniqueIDs := make(map[uint]struct{}, len(request.MappingIDs))
	for _, id := range request.MappingIDs {
		if id == 0 {
			return 0, ErrCatalogLegacyMappingInvalid
		}
		uniqueIDs[id] = struct{}{}
	}
	if len(uniqueIDs) != len(request.MappingIDs) {
		return 0, ErrCatalogLegacyMappingInvalid
	}

	err := m.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if _, err := loadCatalogDocument(tx, packageID); err != nil {
			return err
		}
		var mappings []models.CompetitionCatalogLegacyMapping
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
			Where("package_id = ? AND id IN ?", packageID, request.MappingIDs).
			Order("id ASC").Find(&mappings).Error; err != nil {
			return err
		}
		if len(mappings) != len(request.MappingIDs) {
			return gorm.ErrRecordNotFound
		}
		sort.Slice(mappings, func(left, right int) bool {
			return mappings[left].LegacyEventID < mappings[right].LegacyEventID
		})
		seenLegacyIDs := make(map[uint]struct{}, len(mappings))
		for _, mapping := range mappings {
			if mapping.ReviewStatus == "conflict" {
				return ErrCatalogLegacyMappingConflict
			}
			if _, exists := seenLegacyIDs[mapping.LegacyEventID]; exists {
				return ErrCatalogLegacyMappingConflict
			}
			seenLegacyIDs[mapping.LegacyEventID] = struct{}{}
			if err := validateConfirmedLegacyMapping(tx, mapping); err != nil {
				return err
			}
		}
		now := m.now()
		if err := tx.Model(&models.CompetitionCatalogLegacyMapping{}).
			Where("package_id = ? AND id IN ?", packageID, request.MappingIDs).
			Updates(map[string]any{
				"review_status": "confirmed", "reviewed_by": actorUserID, "reviewed_at": now,
			}).Error; err != nil {
			return err
		}
		return supersedeCatalogPreflights(tx, packageID)
	})
	if err != nil {
		return 0, err
	}
	return len(request.MappingIDs), nil
}

func loadCatalogDocument(tx *gorm.DB, packageID uint) (dto.CompetitionCatalogDocument, error) {
	var catalog models.CompetitionCatalogPackage
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&catalog, packageID).Error; err != nil {
		return dto.CompetitionCatalogDocument{}, err
	}
	var document dto.CompetitionCatalogDocument
	if err := json.Unmarshal(catalog.Payload, &document); err != nil {
		return document, ErrCatalogLegacyMappingInvalid
	}
	return document, nil
}

func loadActiveCatalogPackage(tx *gorm.DB) (models.CompetitionCatalogPackage, error) {
	var active models.CompetitionCatalogPackage
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("is_active = ?", true).First(&active).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return active, ErrCatalogActivePackageRequired
		}
		return active, err
	}
	return active, nil
}

func validateConfirmedLegacyMapping(
	tx *gorm.DB,
	mapping models.CompetitionCatalogLegacyMapping,
) error {
	document, err := loadCatalogDocument(tx, mapping.PackageID)
	if err != nil {
		return err
	}
	found := false
	for _, record := range document.Items {
		if record.CompetitionID == mapping.CompetitionID {
			found = true
			break
		}
	}
	if !found {
		return ErrCatalogLegacyMappingInvalid
	}
	active, err := loadActiveCatalogPackage(tx)
	if err != nil {
		return err
	}
	var event models.CompetitionEvent
	if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).
		Where("id = ? AND catalog_package_id = ?", mapping.LegacyEventID, active.ID).
		First(&event).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return ErrCatalogLegacyMappingInvalid
		}
		return err
	}
	var count int64
	if err := tx.Model(&models.CompetitionCatalogLegacyMapping{}).
		Where("package_id = ? AND legacy_event_id = ? AND review_status = ? AND id <> ?",
			mapping.PackageID, mapping.LegacyEventID, "confirmed", mapping.ID).
		Count(&count).Error; err != nil {
		return err
	}
	if count > 0 {
		return ErrCatalogLegacyMappingConflict
	}
	return nil
}

func supersedeCatalogPreflights(tx *gorm.DB, packageID uint) error {
	if !tx.Migrator().HasTable(&models.CompetitionCatalogActivationSnapshot{}) {
		return nil
	}
	return tx.Model(&models.CompetitionCatalogActivationSnapshot{}).
		Where("package_id = ? AND status = ?", packageID, "ready").
		Update("status", "superseded").Error
}

func scanReferenceCounts(
	tx *gorm.DB,
	table string,
	column string,
	eventIDs []uint,
	target map[uint]int64,
) error {
	type row struct {
		EventID uint
		Count   int64
	}
	var rows []row
	if err := tx.Table(table).Select(column+" AS event_id, COUNT(*) AS count").
		Where(column+" IN ?", eventIDs).Where("deleted_at IS NULL").
		Group(column).Scan(&rows).Error; err != nil {
		return err
	}
	for _, item := range rows {
		target[item.EventID] = item.Count
	}
	return nil
}

func bestLegacyCandidate(
	record dto.CompetitionCatalogRecord,
	events []models.CompetitionEvent,
) (models.CompetitionEvent, string, float64, bool, bool) {
	bestIndex, bestScore, bestType, topScoreCount := -1, 0.0, "", 0
	for index, event := range events {
		score, matchType := legacyMatchScore(record, event)
		if score > bestScore {
			bestIndex, bestScore, bestType = index, score, matchType
			topScoreCount = 1
		} else if score > 0 && math.Abs(score-bestScore) < 0.000001 {
			topScoreCount++
			if bestIndex == -1 || event.ID < events[bestIndex].ID {
				bestIndex, bestType = index, matchType
			}
		}
	}
	if bestIndex < 0 || bestScore < 0.70 {
		return models.CompetitionEvent{}, "", 0, false, false
	}
	return events[bestIndex], bestType, bestScore, topScoreCount > 1, true
}

func legacyMatchScore(
	record dto.CompetitionCatalogRecord,
	event models.CompetitionEvent,
) (float64, string) {
	newTitle, oldTitle := strings.TrimSpace(record.Title), strings.TrimSpace(event.Title)
	if newTitle == "" || oldTitle == "" {
		return 0, ""
	}
	if newTitle == oldTitle {
		return 1, "title_exact"
	}
	normalizedNew, normalizedOld := normalizeCompetitionText(newTitle), normalizeCompetitionText(oldTitle)
	if normalizedNew == normalizedOld {
		return 0.95, "title_normalized"
	}
	similarity := competitionTitleSimilarity(normalizedNew, normalizedOld)
	if similarity < 0.65 {
		return 0, ""
	}
	score, matchType := 0.70, "title_fuzzy"
	if sameNormalizedValue(record.CompetitionLevel, event.CompetitionLevel) {
		score, matchType = 0.85, "title_level"
	} else if sameNormalizedValue(record.Organizer, event.Organizer) ||
		sameNormalizedValue(record.HostUnit, event.HostUnit) {
		score, matchType = 0.82, "title_organizer"
	}
	if sameNormalizedValue(record.SchoolRecognitionGrade, event.SchoolRecognitionGrade) {
		score += 0.02
	}
	if event.PrimaryCategory != nil &&
		sameNormalizedValue(record.PrimaryCategorySlug, event.PrimaryCategory.Slug) {
		score += 0.02
	}
	if record.ParentCompetitionID != "" &&
		sameNormalizedValue(record.ParentCompetitionID, event.ParentCompetitionID) {
		score += 0.01
	}
	if score > 0.94 {
		score = 0.94
	}
	return score, matchType
}

func normalizeCompetitionText(value string) string {
	var builder strings.Builder
	for _, character := range strings.ToLower(strings.TrimSpace(value)) {
		if unicode.IsLetter(character) || unicode.IsDigit(character) {
			builder.WriteRune(character)
		}
	}
	return builder.String()
}

func sameNormalizedValue(left string, right string) bool {
	left = normalizeCompetitionText(left)
	right = normalizeCompetitionText(right)
	return left != "" && left == right
}

func competitionTitleSimilarity(left string, right string) float64 {
	leftRunes, rightRunes := []rune(left), []rune(right)
	if len(leftRunes) == 0 || len(rightRunes) == 0 {
		return 0
	}
	if len(leftRunes) == 1 || len(rightRunes) == 1 {
		if left == right {
			return 1
		}
		return 0
	}
	leftPairs := runePairs(leftRunes)
	rightPairs := runePairs(rightRunes)
	intersection := 0
	for pair, leftCount := range leftPairs {
		if rightCount := rightPairs[pair]; rightCount > 0 {
			if leftCount < rightCount {
				intersection += leftCount
			} else {
				intersection += rightCount
			}
		}
	}
	return 2 * float64(intersection) / float64(len(leftRunes)+len(rightRunes)-2)
}

func runePairs(value []rune) map[string]int {
	result := make(map[string]int, len(value)-1)
	for index := 0; index < len(value)-1; index++ {
		result[string(value[index:index+2])]++
	}
	return result
}
