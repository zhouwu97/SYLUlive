package services

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/competitionmatching"
	"shenliyuan/internal/competitionscope"
	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

type CandidateFilter struct {
	Page                    int
	PageSize                int
	EventID                 uint
	EventIDs                []uint
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
	// traceSamplePercent 控制排序追踪的采样比例（0 表示不写）。
	// 采样判定按 userID 取模，保持确定性：请求路径不允许出现随机数，
	// 否则「同输入同输出」这条治理要求就破了。
	traceSamplePercent int
}

func NewCompetitionCandidateEngine(db *gorm.DB) CompetitionCandidateEngine {
	return &competitionCandidateEngine{
		db: db, context: NewCompetitionUserContextBuilder(db), now: time.Now,
	}
}

// NewCompetitionCandidateEngineWithTraceSample 构造带排序追踪采样的引擎。
func NewCompetitionCandidateEngineWithTraceSample(
	db *gorm.DB,
	percent int,
) CompetitionCandidateEngine {
	engine := &competitionCandidateEngine{
		db: db, context: NewCompetitionUserContextBuilder(db), now: time.Now,
	}
	engine.traceSamplePercent = clampTracePercent(percent)
	return engine
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

func clampTracePercent(percent int) int {
	if percent < 0 {
		return 0
	}
	if percent > 100 {
		return 100
	}
	return percent
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
	result.AlgorithmVersion = competitionmatching.AlgorithmVersion
	if !userContext.ProfileReady {
		// 不再静默返回空结果：客户端需要能区分「没匹配到」与「画像没准备好」，
		// 并且要知道具体缺什么才能给出可操作的引导。
		result.ReasonCode = ReasonProfileIncomplete
		result.MissingFields = userContext.MissingProfileFields()
		return result, nil
	}
	scope, err := competitionscope.Resolve(ctx, e.db)
	if err != nil {
		return result, err
	}
	e.loadCatalogSummary(ctx, scope, &result.Catalog)

	query := scope.ApplyCandidate(
		e.db.WithContext(ctx).Model(&models.CompetitionEvent{}).Preload("PrimaryCategory"),
	)
	if filter.EventID > 0 {
		query = query.Where("competition_events.id = ?", filter.EventID)
	}
	if len(filter.EventIDs) > 0 {
		query = query.Where("competition_events.id IN ?", filter.EventIDs)
	}
	// 诊断计数：只走治理门（含显式 ID 限定）时的条数。
	// 线上「为什么是 0 条」通常卡在治理门与筛选条件之间，
	// 把两个数都返回就不必再靠猜。Session 复制条件以避免计数语句污染后续查询。
	var scopedTotal int64
	if err := query.Session(&gorm.Session{}).Count(&scopedTotal).Error; err != nil {
		return result, err
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

	// 行为信号：一次性聚合，禁止逐候选查库（与 Feed 的既有约定一致）。
	joinedPlans, err := e.loadJoinedPlanEventIDs(ctx, userID)
	if err != nil {
		return result, err
	}
	awardedEvents, err := e.loadAwardedClaimEventIDs(ctx, userID)
	if err != nil {
		return result, err
	}

	resolvedUser := competitionmatching.ResolveUser(competitionmatching.UserProfile{
		Major: userContext.Major, College: userContext.College, EntryYear: userContext.EntryYear,
		Grade:           userContext.Grade,
		ClusterOverride: userContext.MajorClusterOverride,
	})
	if resolvedUser.Unmapped {
		// 专业无映射必须作为可见缺口上报：否则「某些专业永远匹配不到」
		// 会以完全静默的方式复发，也就是本次要修的故障。
		result.ReasonCode = ReasonClusterUnmapped
	}
	preference := competitionmatching.Preference{
		Configured:             userContext.PreferenceConfigured,
		Goals:                  userContext.Goals,
		DirectionTags:          userContext.DirectionTags,
		SkillTags:              userContext.SkillTags,
		PreferredRoles:         userContext.PreferredRoles,
		WeeklyHours:            userContext.WeeklyHours,
		AcceptLongTermTraining: userContext.AcceptLongTermTraining,
		CareerDirection:        userContext.CareerDirection,
	}

	now := e.now()
	ranked := make([]competitionmatching.Ranked, 0, len(events))
	byEventID := make(map[uint]dto.CompetitionCandidateDTO, len(events))
	gradeExcluded := 0
	rankableCount := 0
	for _, event := range events {
		candidate := buildMatchingCandidate(event)
		// 行为信号是逐赛事的，因此在用户偏好基底上叠加一层的副本，
		// 避免逐条重建整个偏好对象时漏字段。
		eventPreference := preference
		eventPreference.JoinedPlan = joinedPlans[event.ID]
		eventPreference.HasAward = awardedEvents[event.ID]
		scored := competitionmatching.Score(competitionmatching.ScoreInput{
			Candidate:  candidate,
			User:       resolvedUser,
			Preference: eventPreference,
			Now:        now,
		})
		// GroupKey 为空表示命中唯一保留的硬门（年级不符），此时才允许淘汰。
		if scored.GroupKey == "" {
			gradeExcluded++
			continue
		}
		dtoItem := buildCompetitionCandidateDTO(event, scored)
		byEventID[event.ID] = dtoItem
		if dtoItem.Gates.PersonalizedRankingAllowed {
			result.Catalog.PersonalizedRankingAllowed = true
			rankableCount++
		}
		ranked = append(ranked, competitionmatching.Ranked{
			ID: event.ID, CompetitionID: dtoItem.CompetitionID, CatalogOrder: event.CatalogOrder,
			Rating: event.CompetitionRating, Importance: event.ImportanceScore, Result: scored,
		})
	}

	ordered := competitionmatching.Rank(ranked, competitionmatching.RankOptions{PageSize: filter.PageSize})
	result.Total = len(ordered)
	start := (filter.Page - 1) * filter.PageSize
	if start > len(ordered) {
		start = len(ordered)
	}
	end := start + filter.PageSize
	if end > len(ordered) {
		end = len(ordered)
	}
	pageItems := ordered[start:end]
	result.HasMore = end < len(ordered)

	labels := map[string]string{
		"major_match": "专业直接相关", "college_match": "学院范围相关",
		"general_match": "通用候选",
	}
	grouped := map[string][]dto.CompetitionCandidateDTO{
		"major_match": {}, "college_match": {}, "general_match": {},
	}
	orderedKeys := []string{"major_match", "college_match", "general_match"}
	for index, item := range pageItems {
		mapped := byEventID[item.ID]
		mapped.RuleOrder = start + index + 1
		grouped[mapped.GroupKey] = append(grouped[mapped.GroupKey], mapped)
	}
	// 组内计数需要按全量而非当前页统计，否则分组标题的条数会随翻页变化。
	fullCounts := map[string]int{}
	for _, item := range ordered {
		fullCounts[byEventID[item.ID].GroupKey]++
	}
	for _, key := range orderedKeys {
		if len(grouped[key]) == 0 {
			continue
		}
		result.Groups = append(result.Groups, dto.CompetitionCandidateGroupDTO{
			Key: key, Label: labels[key], Count: fullCounts[key], Items: grouped[key],
		})
	}
	if result.Total == 0 && result.ReasonCode == "" {
		result.ReasonCode = ReasonNoCandidate
	}
	result.Diagnostics = &dto.CompetitionCandidateDiagnosticsDTO{
		Scoped:        int(scopedTotal),
		Matched:       len(events),
		GradeExcluded: gradeExcluded,
		MajorMatch:    fullCounts["major_match"],
		CollegeMatch:  fullCounts["college_match"],
		GeneralMatch:  fullCounts["general_match"],
		Rankable:      rankableCount,
		Returned:      len(pageItems),
	}
	// 排序追踪是调参依据（计划 §6.2 Rank Trace）：只采样、只记录，不参与任何判定。
	// 写入失败不影响候选结果——埋点不该让用户的列表打不开。
	e.saveRankTrace(ctx, userID, filter, ordered, now)
	return result, nil
}

// saveRankTrace 按确定性采样写入排序追踪。
// 采样判定用 userID 取模而不是随机数：请求路径禁止随机性，否则同一输入可能得到不同输出。
func (e *competitionCandidateEngine) saveRankTrace(
	ctx context.Context,
	userID uint,
	filter CandidateFilter,
	ordered []competitionmatching.Ranked,
	now time.Time,
) {
	percent := e.traceSamplePercent
	if percent <= 0 || len(ordered) == 0 {
		return
	}
	if int(userID%100) >= percent {
		return
	}
	limit := filter.PageSize
	if limit <= 0 || limit > len(ordered) {
		limit = len(ordered)
	}
	rows := make([]models.CompetitionRankTrace, 0, limit)
	runKey := strconv.FormatInt(now.UnixNano(), 36)
	for index := 0; index < limit; index++ {
		item := ordered[index]
		breakdown, err := json.Marshal(item.Result.Breakdown)
		if err != nil {
			continue
		}
		rows = append(rows, models.CompetitionRankTrace{
			UserID: userID, RunKey: runKey,
			EventID: item.ID, CompetitionID: item.CompetitionID, Position: index,
			MatchScore: item.Result.Score, Rankable: item.Result.Rankable,
			Breakdown: datatypes.JSON(breakdown),
			MatchTier: item.Result.Tier, MatchBasis: item.Result.Basis,
			AlgorithmVersion: competitionmatching.AlgorithmVersion,
			CreatedAt:        now,
		})
	}
	if len(rows) == 0 {
		return
	}
	_ = e.db.WithContext(ctx).Create(&rows).Error
}

// ReasonProfileIncomplete 表示画像未就绪，候选无法生成。
const ReasonProfileIncomplete = "profile_incomplete"

// ReasonClusterUnmapped 表示用户专业无簇映射，结果已降级为学院/通用匹配。
const ReasonClusterUnmapped = "cluster_unmapped"

// ReasonNoCandidate 表示管线正常但确实没有候选。
const ReasonNoCandidate = "no_candidate"

// loadJoinedPlanEventIDs 返回用户已加入计划的官方赛事 ID 集合。
func (e *competitionCandidateEngine) loadJoinedPlanEventIDs(
	ctx context.Context,
	userID uint,
) (map[uint]bool, error) {
	var ids []uint
	if err := e.db.WithContext(ctx).Model(&models.UserCompetitionCalendarItem{}).
		Where("user_id = ? AND source_type = ? AND source_event_id IS NOT NULL", userID, "official").
		Distinct().Pluck("source_event_id", &ids).Error; err != nil {
		return nil, err
	}
	result := make(map[uint]bool, len(ids))
	for _, id := range ids {
		result[id] = true
	}
	return result, nil
}

// loadAwardedClaimEventIDs 返回用户已申报过竞赛经历的赛事 ID 集合，避免重复推荐。
func (e *competitionCandidateEngine) loadAwardedClaimEventIDs(
	ctx context.Context,
	userID uint,
) (map[uint]bool, error) {
	var ids []uint
	if err := e.db.WithContext(ctx).Model(&models.UserCompetitionAward{}).
		Where("user_id = ? AND competition_event_id IS NOT NULL", userID).
		Distinct().Pluck("competition_event_id", &ids).Error; err != nil {
		return nil, err
	}
	result := make(map[uint]bool, len(ids))
	for _, id := range ids {
		result[id] = true
	}
	return result, nil
}

// buildMatchingCandidate 把赛事模型投影为匹配所需的纯数据输入。
func buildMatchingCandidate(event models.CompetitionEvent) competitionmatching.Candidate {
	categorySlug := ""
	if event.PrimaryCategory != nil {
		categorySlug = event.PrimaryCategory.Slug
	}
	return competitionmatching.Candidate{
		ID: event.ID, CompetitionID: event.CompetitionID, CatalogOrder: event.CatalogOrder,
		ClusterScope:            competitionmatching.ResolveEventMajors(decodeCompetitionStringArray(event.EligibleMajors)),
		Colleges:                decodeCompetitionStringArray(event.EligibleColleges),
		EntryYears:              decodeCompetitionStringArray(event.EligibleEntryYears),
		Tags:                    decodeCompetitionStringArray(event.Tags),
		CategorySlug:            categorySlug,
		RiskTags:                decodeCompetitionStringArray(event.RiskTags),
		Rating:                  effectiveCompetitionRating(event),
		ImportanceScore:         event.ImportanceScore,
		SchoolRecognitionStatus: event.SchoolRecognitionStatus,
		TimeStatus:              event.TimeStatus,
		RegistrationEnd:         event.RegistrationEnd,
		EventStart:              event.EventStart,
		EvidenceSubgrade:        event.EvidenceSubgrade,
		ParticipationType:       event.ParticipationType,
		TeamSizeMin:             event.TeamSizeMin,
		TeamSizeMax:             event.TeamSizeMax,
		// 与 DTO 的 Gates 保持同一判定，避免打分授权与对外授权口径不一致。
		PersonalizedRankingAllowed: competitionEventRankingAllowed(event),
	}
}

// effectiveCompetitionRating 兼容旧客户端字段，优先使用赛事价值评级。
func effectiveCompetitionRating(event models.CompetitionEvent) string {
	if value := strings.TrimSpace(event.CompetitionRating); value != "" {
		return value
	}
	return strings.TrimSpace(event.RecommendationLevel)
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
	scope competitionscope.Scope,
	summary *dto.CompetitionCatalogSummaryDTO,
) {
	if scope.LegacyFallback || scope.ActivePackageID == nil {
		summary.DatasetVersion = "legacy"
		return
	}
	var catalog models.CompetitionCatalogPackage
	if err := e.db.WithContext(ctx).First(&catalog, *scope.ActivePackageID).Error; err != nil {
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

// competitionEventLegacyCompatible 判断赛事是否来自旧数据（无目录包治理字段）。
func competitionEventLegacyCompatible(event models.CompetitionEvent) bool {
	datasetVersion := strings.TrimSpace(event.DatasetVersion)
	return datasetVersion == "" || datasetVersion == "legacy"
}

// competitionEventRankingAllowed 判定赛事是否被授权参与个性化排序。
// legacy 赛事一律不授权——这与既有实现保持一致，不得放宽。
func competitionEventRankingAllowed(event models.CompetitionEvent) bool {
	return event.PersonalizedRankingAllowed && !competitionEventLegacyCompatible(event)
}

// buildCompetitionCandidateDTO 把赛事模型与匹配结果组装为对外 DTO。
func buildCompetitionCandidateDTO(
	event models.CompetitionEvent,
	scored competitionmatching.Result,
) dto.CompetitionCandidateDTO {
	datasetVersion := strings.TrimSpace(event.DatasetVersion)
	legacyCompatible := competitionEventLegacyCompatible(event)
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

	// 离散匹配维度由打分器给出：这修掉了此前 6 个维度恒为 unknown 的问题。
	dimensions := dto.MatchDimensionsDTO{
		Eligibility: "matched",
		Major:       scored.Dimensions.Major,
		College:     scored.Dimensions.College,
		Grade:       scored.Dimensions.Grade,
		Goal:        scored.Dimensions.Goal,
		Direction:   scored.Dimensions.Direction,
		Skill:       scored.Dimensions.Skill,
		Role:        scored.Dimensions.Role,
		Time:        scored.Dimensions.Time,
		Training:    scored.Dimensions.Training,
	}

	questions := []string{}
	hasPendingInformation := false
	if event.TimeStatus == "pending" || (event.RegistrationEnd == nil && event.EventStart == nil) {
		hasPendingInformation = true
		questions = append(questions, "当届报名或比赛时间尚未核实，请查看官方通知")
	}
	riskTags := decodeCompetitionStringArray(event.RiskTags)
	cautions := PublicCompetitionRisks(riskTags)
	public := publicCompetitionDTO(event)
	public.CompetitionID = competitionID

	coreReason := "符合当前参赛资格，可作为通用候选"
	if len(scored.Reasons) > 0 {
		coreReason = scored.Reasons[0]
	}
	matchedClusters := make([]string, 0, len(scored.MatchedClusters))
	for _, cluster := range scored.MatchedClusters {
		matchedClusters = append(matchedClusters, string(cluster))
	}
	return dto.CompetitionCandidateDTO{
		CompetitionPublicDTO: public,
		ImportanceScore:      event.ImportanceScore, CatalogOrder: event.CatalogOrder,
		GroupKey: scored.GroupKey, HasPendingInformation: hasPendingInformation,
		MatchDimensions: dimensions, CoreReason: coreReason,
		Cautions: cautions, Questions: questions, EvidenceSubgrade: event.EvidenceSubgrade,
		DatasetVersion: datasetVersion, RecordHash: event.RecordHash,
		MatchTier: scored.Tier, MatchBasis: scored.Basis, MatchedClusters: matchedClusters,
		MatchScore:         scored.Score,
		ManualRatingReason: event.ManualRatingReasonPublic,
		MajorFitSummary:    event.MajorFitSummaryPublic,
		EvidenceSummary:    event.EvidenceSummaryPublic,
		RiskTags:           riskTags,
		Gates: dto.RecommendationGateDTO{
			CandidatePoolAllowed:         event.CandidatePoolAllowed || legacyCompatible,
			PersonalizedRankingAllowed:   competitionEventRankingAllowed(event),
			StrongRecommendationEligible: event.StrongRecommendationEligible && !legacyCompatible,
			PermissionLevel:              permissionLevel, AIMode: aiMode,
		},
	}
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

// 已删除 competitionCandidateLess 与 containsCandidateValue：
// 前者只按目录序比较（导致排序与专业无关），后者做专业名全等判定
// （导致主流专业命中为 0 且不命中即淘汰）。两者是本次故障的直接原因，
// 保留会诱导被重新引用。排序改由 competitionmatching.Rank 统一负责。

// PublicCompetitionRisks 只返回已登记的公开风险文案，未知代码不直接透传给学生。
func PublicCompetitionRisks(values []string) []string {
	labels := map[string]string{
		"long_term_training":              "通常需要持续训练",
		"stable_team_required":            "依赖稳定队友",
		"team_dependency":                 "依赖稳定团队协作",
		"time_unconfirmed":                "当届时间待确认",
		"eligibility_unconfirmed":         "参赛资格需复核",
		"high_weekly_hours":               "每周投入较高",
		"high_time_cost":                  "备赛时间成本较高",
		"template_or_material_dependency": "模板和材料依赖较强",
		"mentor_or_resource_dependency":   "导师或平台资源影响较大",
		"contribution_ambiguity":          "团队成员贡献可能难以界定",
		"plagiarism_or_paid_material":     "需特别注意成果原创性",
		"subjective_judging":              "评审存在一定主观性",
		"equipment_dependency":            "对设备或实验条件有依赖",
		"rule_or_track_variation":         "赛道规则可能随届次调整",
		"online_fairness":                 "线上赛公平性需关注",
		"user_feedback_unverified":        "学生反馈尚未核验",
	}
	result := make([]string, 0, len(values))
	unknownFound := false
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if label := labels[value]; label != "" {
			if _, exists := seen[label]; !exists {
				result = append(result, label)
				seen[label] = struct{}{}
			}
		} else {
			unknownFound = true
		}
	}
	if unknownFound {
		result = append(result, "存在待核实风险")
	}
	return result
}

func encodeCandidateDebug(value any) string {
	encoded, _ := json.Marshal(value)
	return fmt.Sprintf("%s", encoded)
}
