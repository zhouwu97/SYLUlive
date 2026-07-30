package services

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

type CandidateFilter struct {
	Page                    int
	PageSize                int
	EventID                 uint
	Keyword                 string
	CategorySlug            string
	SchoolRecognitionStatus string
	DateStatus              string
}

type CompetitionCandidateEngine interface {
	BuildCandidates(context.Context, uint, CandidateFilter) (dto.CompetitionCandidateResultDTO, error)
}

type competitionCandidateEngine struct {
	db      *gorm.DB
	context *CompetitionUserContextBuilder
	now     func() time.Time
}

func NewCompetitionCandidateEngine(db *gorm.DB) CompetitionCandidateEngine {
	return &competitionCandidateEngine{
		db: db, context: NewCompetitionUserContextBuilder(db), now: time.Now,
	}
}

func NewCompetitionCandidateEngineWithClock(
	db *gorm.DB,
	now func() time.Time,
) CompetitionCandidateEngine {
	engine := &competitionCandidateEngine{
		db: db, context: NewCompetitionUserContextBuilder(db), now: now,
	}
	return engine
}

func (e *competitionCandidateEngine) BuildCandidates(
	ctx context.Context,
	userID uint,
	filter CandidateFilter,
) (dto.CompetitionCandidateResultDTO, error) {
	filter = normalizeCandidateFilter(filter)
	result := dto.CompetitionCandidateResultDTO{
		Groups: []dto.CompetitionCandidateGroupDTO{},
		Page:   filter.Page, PageSize: filter.PageSize,
		Catalog: dto.CompetitionCatalogSummaryDTO{Mode: "candidate_explanation"},
	}
	userContext, err := e.context.BuildCompetitionUserContext(ctx, userID)
	if err != nil {
		return result, err
	}
	result.ProfileReady = userContext.ProfileReady
	result.PreferenceConfigured = userContext.PreferenceConfigured
	if !userContext.ProfileReady {
		return result, nil
	}
	e.loadCatalogSummary(ctx, &result.Catalog)

	query := e.db.WithContext(ctx).Model(&models.CompetitionEvent{}).
		Preload("PrimaryCategory").
		Where("status = ?", "published").
		Where("(search_display_allowed = ? OR dataset_version = '' OR dataset_version = 'legacy')", true).
		Where("(candidate_pool_allowed = ? OR dataset_version = '' OR dataset_version = 'legacy')", true)
	if filter.EventID > 0 {
		query = query.Where("competition_events.id = ?", filter.EventID)
	}
	if value := strings.TrimSpace(filter.Keyword); value != "" {
		pattern := "%" + strings.ToLower(value) + "%"
		query = query.Where(
			"LOWER(title) LIKE ? OR LOWER(summary) LIKE ? OR LOWER(description) LIKE ?",
			pattern, pattern, pattern,
		)
	}
	if value := strings.TrimSpace(filter.CategorySlug); value != "" {
		query = query.Joins("JOIN competition_categories ON competition_categories.id = competition_events.primary_category_id").
			Where("competition_categories.slug = ?", value)
	}
	if value := strings.TrimSpace(filter.SchoolRecognitionStatus); value != "" {
		query = query.Where("school_recognition_status = ?", value)
	}
	applyCandidateDateFilter(&query, filter.DateStatus, e.now())

	var events []models.CompetitionEvent
	if err := query.Find(&events).Error; err != nil {
		return result, err
	}
	grouped := map[string][]dto.CompetitionCandidateDTO{
		"major_match": {}, "college_match": {}, "general_match": {}, "needs_confirmation": {},
	}
	for _, event := range events {
		candidate, ok := buildCompetitionCandidate(event, userContext, e.now())
		if !ok {
			continue
		}
		grouped[candidate.GroupKey] = append(grouped[candidate.GroupKey], candidate)
		if candidate.Gates.PersonalizedRankingAllowed {
			result.Catalog.PersonalizedRankingAllowed = true
		}
	}
	for key := range grouped {
		sort.SliceStable(grouped[key], func(i, j int) bool {
			return competitionCandidateLess(grouped[key][i], grouped[key][j], e.now())
		})
	}

	orderedKeys := []string{"major_match", "college_match", "general_match", "needs_confirmation"}
	all := make([]dto.CompetitionCandidateDTO, 0)
	for _, key := range orderedKeys {
		all = append(all, grouped[key]...)
	}
	for index := range all {
		all[index].RuleOrder = index + 1
	}
	result.Total = len(all)
	start := (filter.Page - 1) * filter.PageSize
	if start > len(all) {
		start = len(all)
	}
	end := start + filter.PageSize
	if end > len(all) {
		end = len(all)
	}
	pageItems := all[start:end]
	labels := map[string]string{
		"major_match": "专业直接相关", "college_match": "学院范围相关",
		"general_match": "通用候选", "needs_confirmation": "信息待确认",
	}
	for _, key := range orderedKeys {
		items := make([]dto.CompetitionCandidateDTO, 0)
		for _, item := range pageItems {
			if item.GroupKey == key {
				items = append(items, item)
			}
		}
		if len(items) > 0 {
			result.Groups = append(result.Groups, dto.CompetitionCandidateGroupDTO{
				Key: key, Label: labels[key], Count: len(grouped[key]), Items: items,
			})
		}
	}
	return result, nil
}

func normalizeCandidateFilter(filter CandidateFilter) CandidateFilter {
	if filter.Page < 1 {
		filter.Page = 1
	}
	if filter.PageSize < 1 || filter.PageSize > 50 {
		filter.PageSize = 20
	}
	return filter
}

func (e *competitionCandidateEngine) loadCatalogSummary(
	ctx context.Context,
	summary *dto.CompetitionCatalogSummaryDTO,
) {
	if !e.db.Migrator().HasTable(&models.CompetitionCatalogPackage{}) {
		summary.DatasetVersion = "legacy"
		return
	}
	var catalog models.CompetitionCatalogPackage
	if err := e.db.WithContext(ctx).Where("is_active = ?", true).First(&catalog).Error; err != nil {
		summary.DatasetVersion = "legacy"
		return
	}
	summary.DatasetVersion = catalog.DatasetVersion
	if len(catalog.PackageHash) > 12 {
		summary.PackageHash = catalog.PackageHash[:12]
	} else {
		summary.PackageHash = catalog.PackageHash
	}
}

func applyCandidateDateFilter(query **gorm.DB, status string, now time.Time) {
	switch strings.TrimSpace(status) {
	case "deadline_soon":
		end := now.AddDate(0, 0, 14)
		*query = (*query).Where("registration_end >= ? AND registration_end < ?", now, end)
	case "time_pending":
		*query = (*query).Where("time_status = ? OR (registration_end IS NULL AND event_start IS NULL)", "pending")
	}
}

func buildCompetitionCandidate(
	event models.CompetitionEvent,
	context CompetitionUserContext,
	now time.Time,
) (dto.CompetitionCandidateDTO, bool) {
	datasetVersion := strings.TrimSpace(event.DatasetVersion)
	legacyCompatible := datasetVersion == "" || datasetVersion == "legacy"
	if datasetVersion == "" {
		datasetVersion = "legacy"
	}
	competitionID := strings.TrimSpace(event.CompetitionID)
	if competitionID == "" && legacyCompatible {
		competitionID = fmt.Sprintf("LEGACY-%d", event.ID)
	}
	permissionLevel := strings.TrimSpace(event.RecommendationPermissionLevel)
	if permissionLevel == "" {
		permissionLevel = "low"
	}
	aiMode := strings.TrimSpace(event.AIMode)
	if aiMode == "" {
		aiMode = "candidate_explanation"
	}
	years := decodeCompetitionStringArray(event.EligibleEntryYears)
	colleges := decodeCompetitionStringArray(event.EligibleColleges)
	majors := decodeCompetitionStringArray(event.EligibleMajors)
	dimensions := dto.MatchDimensionsDTO{
		Eligibility: "matched", Major: "unrestricted", College: "unrestricted",
		Grade: "unrestricted", Goal: "unknown", Direction: "unknown", Skill: "unknown",
		Role: "unknown", Time: "unknown", Training: "unknown",
	}
	if len(years) > 0 {
		if !containsCandidateValue(years, context.EntryYear) {
			return dto.CompetitionCandidateDTO{}, false
		}
		dimensions.Grade = "matched"
	}
	groupKey := "general_match"
	coreReason := "符合当前参赛资格，可作为通用候选"
	if len(majors) > 0 {
		if !containsCandidateValue(majors, context.Major) {
			return dto.CompetitionCandidateDTO{}, false
		}
		dimensions.Major = "matched"
		groupKey = "major_match"
		coreReason = "与你的专业方向直接相关"
	} else if len(colleges) > 0 {
		if !containsCandidateValue(colleges, context.College) {
			return dto.CompetitionCandidateDTO{}, false
		}
		dimensions.College = "matched"
		groupKey = "college_match"
		coreReason = "面向你所在学院开放"
	}

	text := strings.ToLower(strings.Join([]string{
		event.Title, event.Summary, event.Description, event.MajorFitSummaryPublic,
		string(event.Tags), event.ParticipationType,
	}, " "))
	dimensions.Goal = candidateDimensionMatch(context.Goals, text)
	dimensions.Direction = candidateDimensionMatch(context.DirectionTags, text)
	skillNames := make([]string, 0, len(context.Skills))
	for _, skill := range context.Skills {
		skillNames = append(skillNames, skill.Name)
	}
	dimensions.Skill = candidateDimensionMatch(skillNames, text)
	dimensions.Role = candidateDimensionMatch(context.PreferredRoles, text)
	if dimensions.Direction == "matched" {
		coreReason += "，并与你关注的方向一致"
	} else if dimensions.Goal == "matched" {
		coreReason += "，也支持你当前的参赛目标"
	}

	requiredHours := candidateWeeklyHours(event, text)
	if context.WeeklyHours > 0 {
		if context.WeeklyHours >= requiredHours {
			dimensions.Time = "matched"
		} else {
			dimensions.Time = "partial"
		}
	}
	longTerm := strings.Contains(text, "长期") || strings.Contains(text, "训练")
	if longTerm {
		if context.AcceptLongTermTraining {
			dimensions.Training = "matched"
		} else {
			dimensions.Training = "partial"
		}
	}
	questions := []string{}
	if event.TimeStatus == "pending" || (event.RegistrationEnd == nil && event.EventStart == nil) {
		groupKey = "needs_confirmation"
		questions = append(questions, "当届报名或比赛时间尚未发布")
	}
	if dimensions.Time == "unknown" {
		questions = append(questions, "每周训练投入仍需确认")
	}
	cautions := publicCompetitionRisks(decodeCompetitionStringArray(event.RiskTags))
	public := publicCompetitionDTO(event)
	public.CompetitionID = competitionID
	return dto.CompetitionCandidateDTO{
		CompetitionPublicDTO: public,
		ImportanceScore:      event.ImportanceScore, CatalogOrder: event.CatalogOrder,
		GroupKey: groupKey, MatchDimensions: dimensions, CoreReason: coreReason,
		Cautions: cautions, Questions: questions, EvidenceSubgrade: event.EvidenceSubgrade,
		DatasetVersion: datasetVersion, RecordHash: event.RecordHash,
		Gates: dto.RecommendationGateDTO{
			CandidatePoolAllowed:         event.CandidatePoolAllowed || legacyCompatible,
			PersonalizedRankingAllowed:   event.PersonalizedRankingAllowed && !legacyCompatible,
			StrongRecommendationEligible: event.StrongRecommendationEligible && !legacyCompatible,
			PermissionLevel:              permissionLevel, AIMode: aiMode,
		},
	}, true
}

func publicCompetitionDTO(event models.CompetitionEvent) dto.CompetitionPublicDTO {
	tags := decodeCompetitionStringArray(event.Tags)
	var category *dto.CompetitionCategoryDTO
	if event.PrimaryCategory != nil {
		category = &dto.CompetitionCategoryDTO{
			ID: event.PrimaryCategory.ID, Name: event.PrimaryCategory.Name,
			Slug: event.PrimaryCategory.Slug, Icon: event.PrimaryCategory.Icon,
		}
	}
	rating := strings.TrimSpace(event.CompetitionRating)
	if rating == "" {
		rating = strings.TrimSpace(event.RecommendationLevel)
	}
	return dto.CompetitionPublicDTO{
		ID: event.ID, CompetitionID: event.CompetitionID, Title: event.Title,
		Summary: event.Summary, Category: category, Tags: tags,
		CompetitionLevel:        event.CompetitionLevel,
		SchoolRecognitionStatus: event.SchoolRecognitionStatus,
		SchoolRecognitionGrade:  event.SchoolRecognitionGrade,
		CompetitionRating:       rating,
		RegistrationTimeText:    event.RegistrationTimeText, EventTimeText: event.EventTimeText,
		TimeStatus: event.TimeStatus, ParticipationType: event.ParticipationType,
		TeamSizeMin: event.TeamSizeMin, TeamSizeMax: event.TeamSizeMax,
		OfficialURL: event.OfficialURL, RegistrationStart: event.RegistrationStart,
		RegistrationEnd: event.RegistrationEnd, EventStart: event.EventStart,
		EventEnd: event.EventEnd, UpdatedAt: event.UpdatedAt,
	}
}

func competitionCandidateLess(left, right dto.CompetitionCandidateDTO, now time.Time) bool {
	leftSoon := candidateDeadlineSoon(left.RegistrationEnd, now)
	rightSoon := candidateDeadlineSoon(right.RegistrationEnd, now)
	if leftSoon != rightSoon {
		return leftSoon
	}
	if left.ImportanceScore != right.ImportanceScore {
		return left.ImportanceScore > right.ImportanceScore
	}
	if left.CatalogOrder != right.CatalogOrder {
		return left.CatalogOrder < right.CatalogOrder
	}
	if left.CompetitionID != right.CompetitionID {
		return left.CompetitionID < right.CompetitionID
	}
	return left.ID < right.ID
}

func candidateDeadlineSoon(deadline *time.Time, now time.Time) bool {
	return deadline != nil && !deadline.Before(now) && deadline.Before(now.AddDate(0, 0, 14))
}

func containsCandidateValue(values []string, expected string) bool {
	expected = strings.TrimSpace(strings.ToLower(expected))
	for _, value := range values {
		if strings.TrimSpace(strings.ToLower(value)) == expected {
			return true
		}
	}
	return false
}

func candidateDimensionMatch(values []string, text string) string {
	if len(values) == 0 {
		return "unknown"
	}
	for _, value := range values {
		if value = strings.TrimSpace(strings.ToLower(value)); value != "" && strings.Contains(text, value) {
			return "matched"
		}
	}
	return "partial"
}

func candidateWeeklyHours(event models.CompetitionEvent, text string) int {
	if strings.Contains(text, "长期") || strings.Contains(text, "训练") {
		return 14
	}
	if event.TeamSizeMax == 1 || strings.Contains(event.ParticipationType, "个人") {
		return 3
	}
	return 7
}

func publicCompetitionRisks(values []string) []string {
	labels := map[string]string{
		"long_term_training":      "通常需要持续训练",
		"stable_team_required":    "依赖稳定队友",
		"time_unconfirmed":        "当届时间待确认",
		"eligibility_unconfirmed": "参赛资格需复核",
		"high_weekly_hours":       "每周投入较高",
	}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if label := labels[value]; label != "" {
			result = append(result, label)
		} else {
			result = append(result, value)
		}
	}
	return result
}

func encodeCandidateDebug(value any) string {
	encoded, _ := json.Marshal(value)
	return fmt.Sprintf("%s", encoded)
}
