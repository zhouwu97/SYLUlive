package handlers

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/gin-gonic/gin"
	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/competitionscope"
	"shenliyuan/internal/models"
)

func competitionRequestContext(c *gin.Context) context.Context {
	if c != nil && c.Request != nil {
		return c.Request.Context()
	}
	return context.Background()
}

type CompetitionHandler struct {
	db                       *gorm.DB
	evidenceDir              string
	maxEvidenceFileSize      int64
	candidateExplanationTool CompetitionCandidateExplanationTool
}

var (
	errCompetitionCatalogManagedReadOnly = errors.New("catalog managed competition event is read only")
	errCompetitionSupersededReadOnly     = errors.New("superseded competition event is read only")
	errCompetitionLegacyReadOnly         = errors.New("legacy competition event is read only")
)

// ensureCompetitionEventMutable 将旧 CRUD 限定为未进入目录治理的手工赛事。
func ensureCompetitionEventMutable(db *gorm.DB, eventID uint) (models.CompetitionEvent, error) {
	var event models.CompetitionEvent
	if err := db.First(&event, eventID).Error; err != nil {
		return event, err
	}
	if event.CatalogPackageID != nil {
		return event, errCompetitionCatalogManagedReadOnly
	}
	if db.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
		var count int64
		if err := db.Model(&models.CompetitionLegacyDuplicateResolution{}).
			Where("duplicate_event_id = ?", eventID).Count(&count).Error; err != nil {
			return event, err
		}
		if count > 0 {
			return event, errCompetitionSupersededReadOnly
		}
	}
	if !strings.HasPrefix(event.CompetitionID, "MANUAL-") {
		return event, errCompetitionLegacyReadOnly
	}
	return event, nil
}

func respondCompetitionEventMutationError(c *gin.Context, err error) bool {
	switch {
	case errors.Is(err, gorm.ErrRecordNotFound):
		c.JSON(http.StatusNotFound, gin.H{"error": "比赛不存在"})
	case errors.Is(err, errCompetitionCatalogManagedReadOnly):
		c.JSON(http.StatusConflict, gin.H{
			"error_code": "catalog_managed_event_read_only",
			"error":      "该赛事由活动目录包管理，请创建新的目录修订后发布",
		})
	case errors.Is(err, errCompetitionSupersededReadOnly):
		c.JSON(http.StatusConflict, gin.H{
			"error_code": "superseded_event_read_only",
			"error":      "该赛事已被历史归并，不允许通过旧管理入口修改",
		})
	case errors.Is(err, errCompetitionLegacyReadOnly):
		c.JSON(http.StatusConflict, gin.H{
			"error_code": "legacy_event_read_only",
			"error":      "只有未纳入目录治理的 MANUAL 赛事可通过旧管理入口修改",
		})
	default:
		return false
	}
	return true
}

func NewCompetitionHandler(db *gorm.DB) *CompetitionHandler {
	return &CompetitionHandler{
		db: db, evidenceDir: filepath.Clean("./private/competition-award-evidence"),
		maxEvidenceFileSize: 10 * 1024 * 1024,
	}
}

// NewCompetitionHandlerWithEvidenceStorage 创建使用独立私有材料目录的竞赛处理器。
func NewCompetitionHandlerWithEvidenceStorage(db *gorm.DB, evidenceDir string, maxFileSize int64) (*CompetitionHandler, error) {
	if strings.TrimSpace(evidenceDir) == "" {
		return nil, fmt.Errorf("竞赛证明材料私有目录不能为空")
	}
	if maxFileSize <= 0 {
		return nil, fmt.Errorf("竞赛证明材料大小限制必须大于 0")
	}
	cleanDir := filepath.Clean(evidenceDir)
	if err := os.MkdirAll(cleanDir, 0o700); err != nil {
		return nil, fmt.Errorf("创建竞赛证明材料私有目录失败: %w", err)
	}
	return &CompetitionHandler{db: db, evidenceDir: cleanDir, maxEvidenceFileSize: maxFileSize}, nil
}

// CompetitionGovernanceDTO 描述赛事治理状态，不复用旧推荐等级推导人工结论。
type CompetitionGovernanceDTO struct {
	ManualRating              *float64 `json:"manual_rating"`
	EvidenceStatus            string   `json:"evidence_status"`
	StrongRecommendationReady bool     `json:"strong_recommendation_ready"`
}

// CompetitionEventDTO 在保持现有扁平响应兼容的同时补齐治理字段。
type CompetitionEventDTO struct {
	models.CompetitionEvent
	CompetitionGovernanceDTO
}

type CompetitionCatalogStateDTO struct {
	PackageID       uint   `json:"package_id"`
	IsActive        bool   `json:"is_active"`
	LifecycleStatus string `json:"lifecycle_status"`
	DatasetVersion  string `json:"dataset_version"`
}

type CompetitionDuplicateStateDTO struct {
	IsCanonical     bool  `json:"is_canonical"`
	SupersededCount int64 `json:"superseded_count"`
}

type AdminCompetitionEventDTO struct {
	CompetitionEventDTO
	ManagementSource string                       `json:"management_source"`
	Mutable          bool                         `json:"mutable"`
	CatalogState     *CompetitionCatalogStateDTO  `json:"catalog_state,omitempty"`
	DuplicateState   CompetitionDuplicateStateDTO `json:"duplicate_state"`
}

type adminCompetitionListSummary struct {
	ActiveCatalog       int64 `json:"active_catalog"`
	ActivePublished     int64 `json:"active_published"`
	DisplayEnabled      int64 `json:"display_enabled"`
	CandidateEnabled    int64 `json:"candidate_enabled"`
	ParentRelationships int64 `json:"parent_relationships"`
	Manual              int64 `json:"manual"`
	Canonical           int64 `json:"canonical"`
	Superseded          int64 `json:"superseded"`
	ResolvedDuplicates  int64 `json:"resolved_duplicates"`
	AllDatabaseRows     int64 `json:"all_database_rows"`
}

func competitionEventDTO(event models.CompetitionEvent) CompetitionEventDTO {
	rating := effectiveCompetitionRating(event)
	event.CompetitionRating = rating
	if strings.TrimSpace(event.RecommendationLevel) == "" {
		event.RecommendationLevel = rating
	}
	evidenceStatus := "pending"
	if event.IsVerified {
		evidenceStatus = "verified"
	}
	return CompetitionEventDTO{
		CompetitionEvent: event,
		CompetitionGovernanceDTO: CompetitionGovernanceDTO{
			ManualRating:              nil,
			EvidenceStatus:            evidenceStatus,
			StrongRecommendationReady: false,
		},
	}
}

func competitionEventDTOs(events []models.CompetitionEvent) []CompetitionEventDTO {
	result := make([]CompetitionEventDTO, len(events))
	for index, event := range events {
		result[index] = competitionEventDTO(event)
	}
	return result
}

func adminCompetitionEventDTOs(
	db *gorm.DB,
	events []models.CompetitionEvent,
	activePackageID *uint,
) ([]AdminCompetitionEventDTO, error) {
	packageIDs := make([]uint, 0)
	eventIDs := make([]uint, 0, len(events))
	for _, event := range events {
		eventIDs = append(eventIDs, event.ID)
		if event.CatalogPackageID != nil {
			packageIDs = append(packageIDs, *event.CatalogPackageID)
		}
	}
	packagesByID := make(map[uint]models.CompetitionCatalogPackage)
	if len(packageIDs) > 0 {
		var packages []models.CompetitionCatalogPackage
		if err := db.Where("id IN ?", packageIDs).Find(&packages).Error; err != nil {
			return nil, err
		}
		for _, catalog := range packages {
			packagesByID[catalog.ID] = catalog
		}
	}

	duplicateIDs := make(map[uint]bool)
	supersededCounts := make(map[uint]int64)
	if len(eventIDs) > 0 && db.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
		var resolutions []models.CompetitionLegacyDuplicateResolution
		if err := db.Where("duplicate_event_id IN ? OR canonical_event_id IN ?", eventIDs, eventIDs).
			Find(&resolutions).Error; err != nil {
			return nil, err
		}
		for _, resolution := range resolutions {
			duplicateIDs[resolution.DuplicateEventID] = true
			supersededCounts[resolution.CanonicalEventID]++
		}
	}

	result := make([]AdminCompetitionEventDTO, 0, len(events))
	for _, event := range events {
		managementSource := "legacy"
		mutable := false
		var catalogState *CompetitionCatalogStateDTO
		if event.CatalogPackageID != nil {
			managementSource = "catalog"
			catalog := packagesByID[*event.CatalogPackageID]
			catalogState = &CompetitionCatalogStateDTO{
				PackageID: *event.CatalogPackageID, IsActive: activePackageID != nil && *activePackageID == *event.CatalogPackageID,
				LifecycleStatus: catalog.LifecycleStatus, DatasetVersion: catalog.DatasetVersion,
			}
		} else if duplicateIDs[event.ID] {
			managementSource = "superseded"
		} else if strings.HasPrefix(event.CompetitionID, "MANUAL-") {
			managementSource = "manual"
			mutable = true
		}
		result = append(result, AdminCompetitionEventDTO{
			CompetitionEventDTO: competitionEventDTO(event), ManagementSource: managementSource,
			Mutable: mutable, CatalogState: catalogState,
			DuplicateState: CompetitionDuplicateStateDTO{
				IsCanonical: !duplicateIDs[event.ID], SupersededCount: supersededCounts[event.ID],
			},
		})
	}
	return result, nil
}

type competitionEventInput struct {
	Title                   string   `json:"title"`
	Subtitle                string   `json:"subtitle"`
	Summary                 string   `json:"summary"`
	Description             string   `json:"description"`
	PrimaryCategoryID       uint     `json:"primary_category_id"`
	PrimaryCategorySlug     string   `json:"primary_category_slug"`
	Tags                    []string `json:"tags"`
	CompetitionLevel        string   `json:"competition_level"`
	SchoolRecognitionStatus string   `json:"school_recognition_status"`
	SchoolRecognitionGrade  string   `json:"school_recognition_grade"`
	CompetitionRating       string   `json:"competition_rating"`
	RecommendationLevel     string   `json:"recommendation_level"`
	ImportanceScore         int      `json:"importance_score"`
	RecommendationReason    string   `json:"recommendation_reason"`
	IsFeatured              bool     `json:"is_featured"`
	IsVerified              bool     `json:"is_verified"`
	Organizer               string   `json:"organizer"`
	HostUnit                string   `json:"host_unit"`
	UndertakeUnit           string   `json:"undertake_unit"`
	TargetAudience          string   `json:"target_audience"`
	EligibleEntryYears      []string `json:"eligible_entry_years"`
	EligibleColleges        []string `json:"eligible_colleges"`
	EligibleMajors          []string `json:"eligible_majors"`
	ParticipationType       string   `json:"participation_type"`
	TeamSizeMin             int      `json:"team_size_min"`
	TeamSizeMax             int      `json:"team_size_max"`
	RegistrationStart       string   `json:"registration_start"`
	RegistrationEnd         string   `json:"registration_end"`
	EventStart              string   `json:"event_start"`
	EventEnd                string   `json:"event_end"`
	RegistrationTimeText    string   `json:"registration_time_text"`
	EventTimeText           string   `json:"event_time_text"`
	TimePrecision           string   `json:"time_precision"`
	TimeStatus              string   `json:"time_status"`
	TimeNote                string   `json:"time_note"`
	SortMonth               int      `json:"sort_month"`
	PlanStatus              string   `json:"plan_status"`
	UserDeadline            string   `json:"user_deadline"`
	Location                string   `json:"location"`
	IsOnline                bool     `json:"is_online"`
	OfficialURL             string   `json:"official_url"`
	NoticeURL               string   `json:"notice_url"`
	AttachmentURLs          []string `json:"attachment_urls"`
	SourceChannel           string   `json:"source_channel"`
	SourceNote              string   `json:"source_note"`
	SourceArticleID         string   `json:"source_article_id"`
	Status                  string   `json:"status"`
}

type categoryInput struct {
	Name        string `json:"name"`
	Slug        string `json:"slug"`
	Description string `json:"description"`
	Icon        string `json:"icon"`
	SortOrder   int    `json:"sort_order"`
	IsActive    *bool  `json:"is_active"`
}

func parseDatePtr(raw string) (*time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	t, err := time.ParseInLocation("2006-01-02", raw, time.Local)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

func jsonArray(values []string) datatypes.JSON {
	if values == nil {
		values = []string{}
	}
	b, _ := json.Marshal(values)
	return datatypes.JSON(b)
}

var entryYearPattern = regexp.MustCompile(`(?:19|20)\d{2}`)

var recommendationRanks = map[string]int{
	"S": 8, "A": 7, "B+": 6, "B": 5, "B-": 4, "C": 3, "D": 2, "E": 1,
}

func effectiveCompetitionRating(event models.CompetitionEvent) string {
	if rating := strings.TrimSpace(event.CompetitionRating); rating != "" {
		return rating
	}
	return strings.TrimSpace(event.RecommendationLevel)
}

type competitionProfile struct {
	EntryYear string
	College   string
	Major     string
}

func shanghaiLocation() *time.Location {
	location, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		return time.FixedZone("Asia/Shanghai", 8*60*60)
	}
	return location
}

func competitionOverviewBounds(now time.Time) (time.Time, time.Time) {
	location := shanghaiLocation()
	localNow := now.In(location)
	start := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 0, 0, 0, 0, location)
	return start, start.AddDate(0, 0, 15)
}

func normalizeEntryYear(value string, now time.Time) string {
	matches := entryYearPattern.FindAllString(value, -1)
	unique := make(map[string]struct{}, len(matches))
	for _, match := range matches {
		unique[match] = struct{}{}
	}
	if len(unique) != 1 {
		return ""
	}
	var year string
	for match := range unique {
		year = match
	}
	parsed, err := strconv.Atoi(year)
	if err != nil || parsed < now.Year()-10 || parsed > now.Year()+1 {
		return ""
	}
	return year
}

func normalizeAcademicName(value string) string {
	value = strings.TrimFunc(strings.TrimSpace(value), unicode.IsPunct)
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

func normalizeStringValues(values []string, normalizer func(string) string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		normalized := normalizer(value)
		if normalized == "" {
			continue
		}
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		result = append(result, normalized)
	}
	return result
}

func normalizeEntryYears(values []string, now time.Time) ([]string, error) {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		normalized := normalizeEntryYear(value, now)
		if normalized == "" {
			return nil, fmt.Errorf("无法识别入学年份：%s", value)
		}
		if _, exists := seen[normalized]; exists {
			continue
		}
		seen[normalized] = struct{}{}
		result = append(result, normalized)
	}
	return result, nil
}

func normalizeRecommendationLevel(value string) (string, error) {
	value = strings.TrimSpace(strings.ToUpper(value))
	if value == "" {
		return "B", nil
	}
	if _, ok := recommendationRanks[value]; !ok {
		return "", fmt.Errorf("推荐等级只能是 S/A/B+/B/B-/C/D/E")
	}
	return value, nil
}

func decodeStringArray(value datatypes.JSON) []string {
	if len(value) == 0 {
		return []string{}
	}
	var result []string
	if err := json.Unmarshal(value, &result); err != nil || result == nil {
		return []string{}
	}
	return result
}

func containsNormalized(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func matchCompetitionForProfile(event models.CompetitionEvent, profile competitionProfile) (bool, string, []string) {
	years := decodeStringArray(event.EligibleEntryYears)
	colleges := decodeStringArray(event.EligibleColleges)
	majors := decodeStringArray(event.EligibleMajors)
	reasons := make([]string, 0, 2)
	if len(years) > 0 {
		if !containsNormalized(years, profile.EntryYear) {
			return false, "", nil
		}
		reasons = append(reasons, "符合"+profile.EntryYear+"级")
	}
	if len(majors) > 0 {
		if !containsNormalized(majors, profile.Major) {
			return false, "", nil
		}
		return true, "major", append(reasons, "专业匹配："+profile.Major)
	}
	if len(colleges) > 0 {
		if !containsNormalized(colleges, profile.College) {
			return false, "", nil
		}
		return true, "college", append(reasons, "学院匹配："+profile.College)
	}
	if len(reasons) == 0 {
		reasons = append(reasons, "不限专业与年级")
	} else {
		reasons = append(reasons, "面向本年级")
	}
	return true, "general", reasons
}

func sortDate(regEnd, eventStart *time.Time, sortMonth int, fallback time.Time) *time.Time {
	if regEnd != nil {
		return regEnd
	}
	if eventStart != nil {
		return eventStart
	}
	if sortMonth >= 1 && sortMonth <= 12 {
		candidate := time.Date(fallback.Year(), time.Month(sortMonth), 1, 0, 0, 0, 0, time.Local)
		if candidate.Before(fallback.AddDate(0, -2, 0)) {
			candidate = candidate.AddDate(1, 0, 0)
		}
		return &candidate
	}
	return nil
}

func normalizeTimePrecision(value string) string {
	switch strings.TrimSpace(value) {
	case "exact", "month", "month_range", "quarter", "half_year", "season", "unknown":
		return strings.TrimSpace(value)
	default:
		return "unknown"
	}
}

func normalizeTimeStatus(value string) string {
	switch strings.TrimSpace(value) {
	case "confirmed", "estimated", "historical", "pending":
		return strings.TrimSpace(value)
	default:
		return "pending"
	}
}

func normalizePlanStatus(value string) string {
	switch strings.TrimSpace(value) {
	case "watching", "preparing", "registered", "submitted", "finished", "archived":
		return strings.TrimSpace(value)
	default:
		return "watching"
	}
}

func normalizeSortMonth(value int) int {
	if value >= 1 && value <= 12 {
		return value
	}
	return 0
}

func validURL(raw string) bool {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return true
	}
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

func randomCode(prefix string, bytesLen int) string {
	b := make([]byte, bytesLen)
	_, _ = rand.Read(b)
	encoded := strings.ToUpper(hex.EncodeToString(b))
	if prefix == "" {
		return encoded
	}
	if len(encoded) >= 8 {
		return fmt.Sprintf("%s-%s-%s", prefix, encoded[:4], encoded[4:8])
	}
	return prefix + "-" + encoded
}

func hashJSON(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func (h *CompetitionHandler) GetCategories(c *gin.Context) {
	var categories []models.CompetitionCategory
	if err := h.db.Where("is_active = ?", true).Order("sort_order ASC").Find(&categories).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取分类失败"})
		return
	}
	c.JSON(http.StatusOK, categories)
}

func (h *CompetitionHandler) GetOverview(c *gin.Context) {
	start, end := competitionOverviewBounds(time.Now())
	ctx := competitionRequestContext(c)
	scope, err := competitionscope.Resolve(ctx, h.db)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛目录范围失败"})
		return
	}
	baseQuery := func() *gorm.DB {
		return scope.ApplyPublic(h.db.WithContext(ctx).Model(&models.CompetitionEvent{}))
	}
	var publishedTotal, deadlineSoonCount, timePendingCount, recognizedCount int64
	if err := baseQuery().Count(&publishedTotal).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛统计失败"})
		return
	}
	if err := baseQuery().
		Where("registration_end >= ? AND registration_end < ?", start, end).
		Count(&deadlineSoonCount).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛统计失败"})
		return
	}
	if err := baseQuery().
		Where("registration_end IS NULL").
		Where("time_status IN ?", []string{"pending", "historical", "estimated"}).
		Count(&timePendingCount).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛统计失败"})
		return
	}
	if err := baseQuery().
		Where("school_recognition_status = ?", "recognized").
		Count(&recognizedCount).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛统计失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"published_total": publishedTotal, "deadline_soon_count": deadlineSoonCount,
		"time_pending_count": timePendingCount, "recognized_count": recognizedCount,
	})
}

func profileFromUser(user models.User, now time.Time) (competitionProfile, bool) {
	profile := competitionProfile{
		EntryYear: normalizeEntryYear(user.EduGrade, now),
		College:   normalizeAcademicName(user.EduCollege),
		Major:     normalizeAcademicName(user.EduMajor),
	}
	return profile, user.IsStudentVerified() && profile.EntryYear != "" && profile.College != "" && profile.Major != ""
}

func (h *CompetitionHandler) GetUserCompetitionState(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var user models.User
	if err := h.db.First(&user, userID).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	var calendarCount int64
	if err := h.db.Model(&models.UserCompetitionCalendarItem{}).
		Where("user_id = ?", userID).Count(&calendarCount).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛状态失败"})
		return
	}
	var joinedIDs []uint
	if err := h.db.Model(&models.UserCompetitionCalendarItem{}).
		Where("user_id = ? AND source_type = ? AND source_event_id IS NOT NULL", userID, "official").
		Distinct().Pluck("source_event_id", &joinedIDs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛状态失败"})
		return
	}
	_, profileReady := profileFromUser(user, time.Now())
	c.JSON(http.StatusOK, gin.H{
		"calendar_count": calendarCount, "joined_event_ids": joinedIDs, "profile_ready": profileReady,
	})
}

func (h *CompetitionHandler) ListFitEvents(c *gin.Context) {
	h.listLegacyFitEvents(c)
}

func (h *CompetitionHandler) AdminCompetitionAudienceOptions(c *gin.Context) {
	var users []models.User
	if err := h.db.Select("edu_grade", "edu_college", "edu_major").
		Where("student_verified_at IS NOT NULL OR edu_bound = ?", true).
		Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取画像选项失败"})
		return
	}
	yearSet := map[string]struct{}{}
	collegeSet := map[string]struct{}{}
	majorSet := map[string]struct{}{}
	for _, user := range users {
		if year := normalizeEntryYear(user.EduGrade, time.Now()); year != "" {
			yearSet[year] = struct{}{}
		}
		if college := normalizeAcademicName(user.EduCollege); college != "" {
			collegeSet[college] = struct{}{}
		}
		if major := normalizeAcademicName(user.EduMajor); major != "" {
			majorSet[major] = struct{}{}
		}
	}
	toSorted := func(values map[string]struct{}) []string {
		result := make([]string, 0, len(values))
		for value := range values {
			result = append(result, value)
		}
		sort.Strings(result)
		return result
	}
	c.JSON(http.StatusOK, gin.H{
		"entry_years": toSorted(yearSet), "colleges": toSorted(collegeSet), "majors": toSorted(majorSet),
	})
}

func (h *CompetitionHandler) ListEvents(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}
	ctx := competitionRequestContext(c)
	scope, err := competitionscope.Resolve(ctx, h.db)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛目录范围失败"})
		return
	}
	query := scope.ApplyPublic(
		h.db.WithContext(ctx).Model(&models.CompetitionEvent{}).Preload("PrimaryCategory"),
	)
	query = h.applyEventFilters(c, query)

	var total int64
	query.Count(&total)
	var events []models.CompetitionEvent
	if err := query.Order("sort_date ASC NULLS LAST").Order("importance_score DESC").
		Offset((page - 1) * pageSize).Limit(pageSize).Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取比赛列表失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": competitionEventDTOs(events), "total": total, "page": page, "page_size": pageSize})
}

func (h *CompetitionHandler) applyEventFilters(c *gin.Context, query *gorm.DB) *gorm.DB {
	if keyword := strings.TrimSpace(strings.ToLower(c.Query("keyword"))); keyword != "" {
		like := "%" + keyword + "%"
		query = query.Where("(LOWER(title) LIKE ? OR LOWER(organizer) LIKE ? OR LOWER(CAST(tags AS TEXT)) LIKE ?)", like, like, like)
	}
	if slug := strings.TrimSpace(c.Query("category_slug")); slug != "" {
		query = query.Joins("JOIN competition_categories cc ON cc.id = competition_events.primary_category_id").
			Where("cc.slug = ?", slug)
	}
	for _, key := range []string{"school_recognition_status", "school_recognition_grade", "source_channel", "competition_level", "time_status", "time_precision"} {
		if value := strings.TrimSpace(c.Query(key)); value != "" {
			query = query.Where(key+" IN ?", strings.Split(value, ","))
		}
	}
	ratingFilter := strings.TrimSpace(c.Query("competition_rating"))
	if ratingFilter == "" {
		ratingFilter = strings.TrimSpace(c.Query("recommendation_level"))
	}
	if ratingFilter != "" {
		query = query.Where("COALESCE(NULLIF(competition_rating, ''), recommendation_level) IN ?", strings.Split(ratingFilter, ","))
	}
	if c.Query("is_featured") != "" {
		query = query.Where("is_featured = ?", c.Query("is_featured") == "true")
	}
	if c.Query("is_online") != "" {
		query = query.Where("is_online = ?", c.Query("is_online") == "true")
	}
	switch c.Query("date_status") {
	case "deadline_soon":
		start, end := competitionOverviewBounds(time.Now())
		query = query.Where("registration_end IS NOT NULL AND registration_end >= ? AND registration_end < ?", start, end)
	case "registering":
		query = query.Where("(registration_start IS NULL OR registration_start <= ?) AND (registration_end IS NULL OR registration_end >= ?)", time.Now(), time.Now())
	case "not_started":
		query = query.Where("registration_start > ?", time.Now())
	case "ended":
		query = query.Where("COALESCE(event_end, registration_end, event_start) < ?", time.Now())
	case "time_pending":
		query = query.Where("registration_end IS NULL").
			Where("time_status IN ?", []string{"pending", "historical", "estimated"})
	}
	return query
}

func (h *CompetitionHandler) GetEvent(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	ctx := competitionRequestContext(c)
	scope, err := competitionscope.Resolve(ctx, h.db)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛目录范围失败"})
		return
	}
	var event models.CompetitionEvent
	query := scope.ApplyPublic(h.db.WithContext(ctx).Preload("PrimaryCategory").Model(&models.CompetitionEvent{}))
	if err := query.First(&event, "competition_events.id = ?", id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "比赛不存在"})
		return
	}
	c.JSON(http.StatusOK, competitionEventDTO(event))
}

func (h *CompetitionHandler) AdminCreateCategory(c *gin.Context) {
	var input categoryInput
	if err := c.ShouldBindJSON(&input); err != nil || strings.TrimSpace(input.Name) == "" || strings.TrimSpace(input.Slug) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "分类名称和 slug 不能为空"})
		return
	}
	active := true
	if input.IsActive != nil {
		active = *input.IsActive
	}
	category := models.CompetitionCategory{
		Name: strings.TrimSpace(input.Name), Slug: strings.TrimSpace(input.Slug),
		Description: input.Description, Icon: input.Icon, SortOrder: input.SortOrder, IsActive: active,
	}
	if err := h.db.Create(&category).Error; err != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "分类 slug 已存在"})
		return
	}
	c.JSON(http.StatusCreated, category)
}

func (h *CompetitionHandler) AdminUpdateCategory(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input categoryInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	var category models.CompetitionCategory
	if err := h.db.First(&category, id).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "分类不存在"})
		return
	}
	referenced, err := h.catalogReferencesCategory(id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查分类目录引用失败"})
		return
	}
	if referenced && ((strings.TrimSpace(input.Slug) != "" && strings.TrimSpace(input.Slug) != category.Slug) ||
		(input.IsActive != nil && !*input.IsActive)) {
		respondCatalogCategoryIdentityReadOnly(c)
		return
	}
	updates := map[string]interface{}{}
	if input.Name != "" {
		updates["name"] = strings.TrimSpace(input.Name)
	}
	if input.Slug != "" {
		updates["slug"] = strings.TrimSpace(input.Slug)
	}
	updates["description"] = input.Description
	updates["icon"] = input.Icon
	updates["sort_order"] = input.SortOrder
	if input.IsActive != nil {
		updates["is_active"] = *input.IsActive
	}
	if err := h.db.Model(&models.CompetitionCategory{}).Where("id = ?", id).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新分类失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已更新"})
}

func (h *CompetitionHandler) AdminDeleteCategory(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	referenced, err := h.catalogReferencesCategory(id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "检查分类目录引用失败"})
		return
	}
	if referenced {
		respondCatalogCategoryIdentityReadOnly(c)
		return
	}
	if err := h.db.Model(&models.CompetitionCategory{}).Where("id = ?", id).Update("is_active", false).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除分类失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已停用分类"})
}

func (h *CompetitionHandler) catalogReferencesCategory(categoryID uint) (bool, error) {
	var count int64
	err := h.db.Model(&models.CompetitionEvent{}).
		Where("primary_category_id = ? AND catalog_package_id IS NOT NULL", categoryID).
		Count(&count).Error
	return count > 0, err
}

func respondCatalogCategoryIdentityReadOnly(c *gin.Context) {
	c.JSON(http.StatusConflict, gin.H{
		"error_code": "catalog_category_identity_read_only",
		"error":      "该分类已被目录包引用，不能修改 slug、停用或删除",
	})
}

func (h *CompetitionHandler) AdminListEvents(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}
	scope, activePackageID, err := resolveAdminCompetitionScope(h.db, c.Query("scope"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	query := applyAdminCompetitionScope(
		h.db.Model(&models.CompetitionEvent{}).Preload("PrimaryCategory"),
		h.db, scope, activePackageID,
	)
	filter := parseAdminFilterFromQuery(c)
	query = applyAdminCompetitionFilter(query, filter, time.Now())
	var total int64
	if err := query.Count(&total).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "统计比赛失败"})
		return
	}
	var events []models.CompetitionEvent
	if err := query.Order("updated_at DESC").Offset((page - 1) * pageSize).Limit(pageSize).Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取比赛失败"})
		return
	}

	totalPages := int((total + int64(pageSize) - 1) / int64(pageSize))
	if totalPages == 0 {
		totalPages = 1
	}
	items, err := adminCompetitionEventDTOs(h.db, events, activePackageID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取比赛治理状态失败"})
		return
	}
	summary, err := buildAdminCompetitionListSummary(h.db, activePackageID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "统计比赛治理范围失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"items":       items,
		"total":       total,
		"page":        page,
		"page_size":   pageSize,
		"total_pages": totalPages,
		"scope":       scope,
		"summary":     summary,
	})
}

func resolveAdminCompetitionScope(db *gorm.DB, requested string) (string, *uint, error) {
	requested = strings.TrimSpace(strings.ToLower(requested))
	valid := map[string]bool{"active": true, "canonical": true, "manual": true, "superseded": true, "all": true}
	if requested != "" && !valid[requested] {
		return "", nil, fmt.Errorf("scope 必须是 active、canonical、manual、superseded 或 all")
	}
	var active models.CompetitionCatalogPackage
	err := db.Where("is_active = ?", true).First(&active).Error
	if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return "", nil, err
	}
	var activeID *uint
	if err == nil {
		value := active.ID
		activeID = &value
	}
	if requested == "" {
		if activeID != nil {
			return "active", activeID, nil
		}
		return "canonical", nil, nil
	}
	return requested, activeID, nil
}

func applyAdminCompetitionScope(query, db *gorm.DB, scope string, activePackageID *uint) *gorm.DB {
	switch scope {
	case "active":
		if activePackageID == nil {
			return query.Where("1 = 0")
		}
		return query.Where("competition_events.catalog_package_id = ?", *activePackageID)
	case "manual":
		return query.Where("competition_events.catalog_package_id IS NULL").
			Where("competition_events.competition_id LIKE ?", "MANUAL-%")
	case "superseded":
		if !db.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
			return query.Where("1 = 0")
		}
		duplicateIDs := db.Model(&models.CompetitionLegacyDuplicateResolution{}).Select("duplicate_event_id")
		return query.Where("competition_events.id IN (?)", duplicateIDs)
	case "canonical":
		if !db.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
			return query
		}
		duplicateIDs := db.Model(&models.CompetitionLegacyDuplicateResolution{}).Select("duplicate_event_id")
		return query.Where("competition_events.id NOT IN (?)", duplicateIDs)
	default:
		return query
	}
}

func buildAdminCompetitionListSummary(db *gorm.DB, activePackageID *uint) (adminCompetitionListSummary, error) {
	summary := adminCompetitionListSummary{}
	base := db.Model(&models.CompetitionEvent{})
	if err := base.Count(&summary.AllDatabaseRows).Error; err != nil {
		return summary, err
	}
	if activePackageID != nil {
		activeQuery := db.Model(&models.CompetitionEvent{}).
			Where("catalog_package_id = ?", *activePackageID)
		if err := activeQuery.Count(&summary.ActiveCatalog).Error; err != nil {
			return summary, err
		}
		if err := db.Model(&models.CompetitionEvent{}).
			Where("catalog_package_id = ? AND status = ?", *activePackageID, "published").
			Count(&summary.ActivePublished).Error; err != nil {
			return summary, err
		}
		if err := db.Model(&models.CompetitionEvent{}).
			Where("catalog_package_id = ? AND search_display_allowed = ?", *activePackageID, true).
			Count(&summary.DisplayEnabled).Error; err != nil {
			return summary, err
		}
		if err := db.Model(&models.CompetitionEvent{}).
			Where("catalog_package_id = ? AND candidate_pool_allowed = ?", *activePackageID, true).
			Count(&summary.CandidateEnabled).Error; err != nil {
			return summary, err
		}
		if err := db.Model(&models.CompetitionEvent{}).
			Where("catalog_package_id = ? AND parent_event_id IS NOT NULL", *activePackageID).
			Count(&summary.ParentRelationships).Error; err != nil {
			return summary, err
		}
	}
	if err := db.Model(&models.CompetitionEvent{}).
		Where("catalog_package_id IS NULL AND competition_id LIKE ?", "MANUAL-%").
		Count(&summary.Manual).Error; err != nil {
		return summary, err
	}
	if db.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
		if err := db.Model(&models.CompetitionLegacyDuplicateResolution{}).
			Count(&summary.ResolvedDuplicates).Error; err != nil {
			return summary, err
		}
		duplicateIDs := db.Model(&models.CompetitionLegacyDuplicateResolution{}).Select("duplicate_event_id")
		if err := db.Model(&models.CompetitionEvent{}).
			Where("id IN (?)", duplicateIDs).Count(&summary.Superseded).Error; err != nil {
			return summary, err
		}
		if err := db.Model(&models.CompetitionEvent{}).
			Where("id NOT IN (?)", duplicateIDs).Count(&summary.Canonical).Error; err != nil {
			return summary, err
		}
	} else {
		summary.Canonical = summary.AllDatabaseRows
	}
	return summary, nil
}

func parseAdminFilterFromQuery(c *gin.Context) adminCompetitionFilter {
	filter := adminCompetitionFilter{
		Scope:             strings.TrimSpace(c.Query("scope")),
		Status:            strings.TrimSpace(c.Query("status")),
		MaintenanceStatus: strings.TrimSpace(c.Query("maintenance_status")),
		CategorySlug:      strings.TrimSpace(c.Query("category_slug")),
		Keyword:           strings.TrimSpace(strings.ToLower(c.Query("keyword"))),
	}
	recStr := strings.TrimSpace(c.Query("competition_rating"))
	if recStr == "" {
		recStr = strings.TrimSpace(c.Query("recommendation_level"))
	}
	if recStr != "" {
		filter.RecommendationLevels = strings.Split(recStr, ",")
	}
	return filter
}

func applyAdminCompetitionFilter(query *gorm.DB, filter adminCompetitionFilter, now time.Time) *gorm.DB {
	if filter.Status != "" && filter.Status != "all" {
		query = query.Where("status = ?", filter.Status)
	}

	if filter.Keyword != "" {
		like := "%" + filter.Keyword + "%"
		query = query.Where("(LOWER(title) LIKE ? OR LOWER(organizer) LIKE ? OR LOWER(CAST(tags AS TEXT)) LIKE ?)", like, like, like)
	}

	if filter.CategorySlug != "" {
		query = query.Joins("JOIN competition_categories cc ON cc.id = competition_events.primary_category_id").
			Where("cc.slug = ?", filter.CategorySlug)
	}

	if len(filter.RecommendationLevels) > 0 {
		query = query.Where("COALESCE(NULLIF(competition_rating, ''), recommendation_level) IN ?", filter.RecommendationLevels)
	}

	switch filter.MaintenanceStatus {
	case "time_pending":
		query = query.Where("registration_end IS NULL").
			Where("time_status IN ?", []string{"pending", "historical", "estimated"})
	case "stale":
		currentMonth := int(now.Month())
		nextMonth := int(now.AddDate(0, 1, 0).Month())
		query = query.Where(
			"updated_at < ? OR (registration_end IS NULL AND sort_month IN ?)",
			now.AddDate(0, 0, -180),
			[]int{currentMonth, nextMonth},
		)
	case "ai_draft":
		query = query.Where("source_channel = ? AND status = ?", "ai_import", "draft")
	case "ending_soon":
		query = query.Where("registration_end IS NOT NULL AND registration_end BETWEEN ? AND ?", now, now.AddDate(0, 0, 14))
	case "expired":
		query = query.Where("COALESCE(event_end, registration_end, event_start) < ?", now)
	case "unverified":
		query = query.Where(
			"(is_verified = ? OR time_status = ? OR school_recognition_status = ?)",
			false,
			"pending",
			"pending",
		)
	}
	return query
}

func (h *CompetitionHandler) AdminCreateEvent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input competitionEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	event, err := h.eventFromInput(input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	event.CreatedBy = userID
	event.UpdatedBy = userID
	if event.Status == "" {
		event.Status = "draft"
	}
	if err := h.db.Create(&event).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建比赛失败"})
		return
	}
	c.JSON(http.StatusCreated, competitionEventDTO(event))
}

func (h *CompetitionHandler) AdminUpdateEvent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	if _, err := ensureCompetitionEventMutable(h.db, id); err != nil {
		if !respondCompetitionEventMutationError(c, err) {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "检查比赛治理状态失败"})
		}
		return
	}
	var input competitionEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	event, err := h.eventFromInput(input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	event.ID = id
	event.UpdatedBy = userID
	if err := h.db.Model(&models.CompetitionEvent{}).Where("id = ?", id).
		Updates(event).UpdateColumn("version", gorm.Expr("version + 1")).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新比赛失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已更新"})
}

func (h *CompetitionHandler) eventFromInput(input competitionEventInput) (models.CompetitionEvent, error) {
	input.Title = strings.TrimSpace(input.Title)
	if input.Title == "" {
		return models.CompetitionEvent{}, fmt.Errorf("比赛标题不能为空")
	}
	if !validURL(input.OfficialURL) || !validURL(input.NoticeURL) {
		return models.CompetitionEvent{}, fmt.Errorf("URL 必须是 http/https")
	}
	regStart, err := parseDatePtr(input.RegistrationStart)
	if err != nil {
		return models.CompetitionEvent{}, fmt.Errorf("报名开始日期格式错误，应为 YYYY-MM-DD")
	}
	regEnd, err := parseDatePtr(input.RegistrationEnd)
	if err != nil {
		return models.CompetitionEvent{}, fmt.Errorf("报名截止日期格式错误，应为 YYYY-MM-DD")
	}
	eventStart, err := parseDatePtr(input.EventStart)
	if err != nil {
		return models.CompetitionEvent{}, fmt.Errorf("比赛开始日期格式错误，应为 YYYY-MM-DD")
	}
	eventEnd, err := parseDatePtr(input.EventEnd)
	if err != nil {
		return models.CompetitionEvent{}, fmt.Errorf("比赛结束日期格式错误，应为 YYYY-MM-DD")
	}
	if regStart != nil && regEnd != nil && regEnd.Before(*regStart) {
		return models.CompetitionEvent{}, fmt.Errorf("报名截止不能早于报名开始")
	}
	if eventStart != nil && eventEnd != nil && eventEnd.Before(*eventStart) {
		return models.CompetitionEvent{}, fmt.Errorf("比赛结束不能早于比赛开始")
	}
	categoryID := input.PrimaryCategoryID
	if categoryID == 0 && input.PrimaryCategorySlug != "" {
		var category models.CompetitionCategory
		if err := h.db.Where("slug = ?", input.PrimaryCategorySlug).First(&category).Error; err != nil {
			return models.CompetitionEvent{}, fmt.Errorf("分类不存在：%s", input.PrimaryCategorySlug)
		}
		categoryID = category.ID
	}
	if categoryID == 0 {
		return models.CompetitionEvent{}, fmt.Errorf("请选择主分类")
	}
	now := time.Now()
	ratingInput := input.CompetitionRating
	if strings.TrimSpace(ratingInput) == "" {
		ratingInput = input.RecommendationLevel
	}
	competitionRating, err := normalizeRecommendationLevel(ratingInput)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	entryYears, err := normalizeEntryYears(input.EligibleEntryYears, now)
	if err != nil {
		return models.CompetitionEvent{}, err
	}
	colleges := normalizeStringValues(input.EligibleColleges, normalizeAcademicName)
	majors := normalizeStringValues(input.EligibleMajors, normalizeAcademicName)
	sortMonth := normalizeSortMonth(input.SortMonth)
	timePrecision := normalizeTimePrecision(input.TimePrecision)
	timeStatus := normalizeTimeStatus(input.TimeStatus)
	if regEnd != nil && strings.TrimSpace(input.TimePrecision) == "" {
		timePrecision = "exact"
	}
	if regEnd != nil && strings.TrimSpace(input.TimeStatus) == "" {
		timeStatus = "confirmed"
	}
	competitionID := randomCode("MANUAL", 8)
	criticalHash, _ := json.Marshal(map[string]interface{}{
		"competition_id": competitionID,
		"title":          strings.TrimSpace(input.Title),
		"registration":   regEnd,
		"event_start":    eventStart,
	})
	return models.CompetitionEvent{
		CompetitionID: competitionID, DatasetVersion: "legacy", RecordHash: hashJSON(criticalHash),
		SearchDisplayAllowed: true, CandidatePoolAllowed: true,
		PersonalizedRankingAllowed: false, StrongRecommendationEligible: false,
		RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
		RiskTags: jsonArray([]string{}), BlockerCodes: jsonArray([]string{}),
		Title: input.Title, Subtitle: input.Subtitle, Summary: input.Summary, Description: input.Description,
		PrimaryCategoryID: categoryID, Tags: jsonArray(input.Tags), CompetitionLevel: input.CompetitionLevel,
		SchoolRecognitionStatus: input.SchoolRecognitionStatus, SchoolRecognitionGrade: input.SchoolRecognitionGrade,
		CompetitionRating: competitionRating, RecommendationLevel: competitionRating,
		ImportanceScore:      input.ImportanceScore,
		RecommendationReason: input.RecommendationReason, IsFeatured: input.IsFeatured, IsVerified: input.IsVerified,
		Organizer: input.Organizer, HostUnit: input.HostUnit, UndertakeUnit: input.UndertakeUnit,
		TargetAudience: input.TargetAudience, EligibleEntryYears: jsonArray(entryYears),
		EligibleColleges: jsonArray(colleges), EligibleMajors: jsonArray(majors), ParticipationType: input.ParticipationType,
		TeamSizeMin: input.TeamSizeMin, TeamSizeMax: input.TeamSizeMax,
		RegistrationStart: regStart, RegistrationEnd: regEnd, EventStart: eventStart, EventEnd: eventEnd,
		RegistrationTimeText: input.RegistrationTimeText, EventTimeText: input.EventTimeText,
		TimePrecision: timePrecision, TimeStatus: timeStatus, TimeNote: strings.TrimSpace(input.TimeNote),
		SortMonth: sortMonth, SortDate: sortDate(regEnd, eventStart, sortMonth, now),
		Location: input.Location, IsOnline: input.IsOnline,
		OfficialURL: input.OfficialURL, NoticeURL: input.NoticeURL, AttachmentURLs: jsonArray(input.AttachmentURLs),
		SourceChannel: input.SourceChannel, SourceNote: input.SourceNote, SourceArticleID: input.SourceArticleID,
		Status: input.Status,
	}, nil
}

func (h *CompetitionHandler) AdminArchiveEvent(c *gin.Context) {
	h.performSingleAction(c, "archive")
}

func (h *CompetitionHandler) AdminPublishEvent(c *gin.Context) {
	h.performSingleAction(c, "publish")
}

func (h *CompetitionHandler) AdminRestoreEvent(c *gin.Context) {
	h.performSingleAction(c, "restore_to_draft")
}

func (h *CompetitionHandler) AdminDeleteEvent(c *gin.Context) {
	h.performSingleAction(c, "delete")
}

func (h *CompetitionHandler) performSingleAction(c *gin.Context, action string) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	event, err := ensureCompetitionEventMutable(h.db, id)
	if err != nil {
		if !respondCompetitionEventMutationError(c, err) {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "检查比赛治理状态失败"})
		}
		return
	}

	newStatus, err := checkEventStatusTransition(event.Status, action)
	if err != nil {
		c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
		return
	}

	if action == "delete" {
		if err := h.db.Transaction(func(tx *gorm.DB) error {
			if err := tx.Model(&event).UpdateColumn("updated_by", userID).Error; err != nil {
				return err
			}
			return tx.Delete(&event).Error
		}); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"message": "已删除"})
		return
	}

	updates := map[string]interface{}{"status": newStatus, "updated_by": userID}
	if newStatus == "archived" {
		now := time.Now()
		updates["archived_at"] = &now
	} else if newStatus == "draft" || newStatus == "published" {
		updates["archived_at"] = gorm.Expr("NULL")
	}

	if err := h.db.Model(&event).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "操作失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "操作成功"})
}

func checkEventStatusTransition(currentStatus, action string) (string, error) {
	switch action {
	case "publish":
		if currentStatus == "draft" {
			return "published", nil
		}
		if currentStatus == "published" {
			return "published", fmt.Errorf("已经是发布状态")
		}
		return "", fmt.Errorf("已归档比赛需要先恢复为草稿")
	case "archive":
		if currentStatus == "archived" {
			return "archived", fmt.Errorf("已经是归档状态")
		}
		return "archived", nil
	case "restore_to_draft":
		if currentStatus == "archived" {
			return "draft", nil
		}
		if currentStatus == "draft" {
			return "draft", fmt.Errorf("已经是草稿状态")
		}
		return "", fmt.Errorf("只有已归档的比赛才能恢复为草稿")
	case "delete":
		if currentStatus == "draft" || currentStatus == "archived" {
			return "deleted", nil
		}
		return "", fmt.Errorf("已发布的比赛必须先归档后才能删除")
	default:
		return "", fmt.Errorf("未知的操作")
	}
}

type adminCompetitionFilter struct {
	Scope                string   `json:"scope"`
	Status               string   `json:"status"`
	MaintenanceStatus    string   `json:"maintenance_status"`
	CategorySlug         string   `json:"category_slug"`
	RecommendationLevels []string `json:"recommendation_levels"`
	Keyword              string   `json:"keyword"`
}

type adminBatchSelection struct {
	Mode        string                 `json:"mode"`
	IDs         []uint                 `json:"ids,omitempty"`
	ExcludedIDs []uint                 `json:"excluded_ids,omitempty"`
	Filters     adminCompetitionFilter `json:"filters,omitempty"`
}

type adminBatchActionInput struct {
	Action    string               `json:"action"`
	IDs       []uint               `json:"ids,omitempty"`
	Selection *adminBatchSelection `json:"selection,omitempty"`
	DryRun    bool                 `json:"dry_run,omitempty"`
}

type batchSkippedDetail struct {
	ID     uint   `json:"id"`
	Reason string `json:"reason"`
}

func (h *CompetitionHandler) AdminBatchAction(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input adminBatchActionInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	var targetIDs []uint
	var totalMatched int64

	if input.Selection != nil && input.Selection.Mode == "query" {
		scope, activePackageID, err := resolveAdminCompetitionScope(h.db, input.Selection.Filters.Scope)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		queryCount := applyAdminCompetitionScope(
			applyAdminCompetitionFilter(h.db.Model(&models.CompetitionEvent{}), input.Selection.Filters, time.Now()),
			h.db, scope, activePackageID,
		)
		if err := queryCount.Count(&totalMatched).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "计算匹配数量失败"})
			return
		}

		if totalMatched > 5000 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "单次查询模式批量操作最多匹配 5000 项"})
			return
		}

		query := applyAdminCompetitionScope(
			applyAdminCompetitionFilter(h.db.Model(&models.CompetitionEvent{}), input.Selection.Filters, time.Now()),
			h.db, scope, activePackageID,
		)
		if len(input.Selection.ExcludedIDs) > 0 {
			query = query.Where("id NOT IN ?", input.Selection.ExcludedIDs)
		}

		if err := query.Pluck("id", &targetIDs).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询匹配数据失败"})
			return
		}
	} else if input.Selection != nil && input.Selection.Mode == "ids" {
		targetIDs = input.Selection.IDs
		totalMatched = int64(len(targetIDs))
	} else if len(input.IDs) > 0 {
		targetIDs = input.IDs // legacy fallback
		totalMatched = int64(len(targetIDs))
	} else {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请提供批量操作目标"})
		return
	}

	if len(targetIDs) == 0 {
		c.JSON(http.StatusOK, gin.H{
			"matched_count": totalMatched, "requested_count": 0, "success_count": 0, "skipped_count": 0, "skipped_reasons": []interface{}{}, "skipped": []interface{}{},
		})
		return
	}

	if (input.Selection == nil || input.Selection.Mode != "query") && len(targetIDs) > 200 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次 IDs 模式批量操作最多 200 项"})
		return
	}

	uniqueIDs := make(map[uint]struct{}, len(targetIDs))
	var cleanIDs []uint
	for _, id := range targetIDs {
		if _, exists := uniqueIDs[id]; !exists {
			uniqueIDs[id] = struct{}{}
			cleanIDs = append(cleanIDs, id)
		}
	}

	type batchEventState struct {
		ID               uint
		Status           string
		CompetitionID    string
		CatalogPackageID *uint
	}
	var states []batchEventState
	if err := h.db.Model(&models.CompetitionEvent{}).
		Select("id", "status", "competition_id", "catalog_package_id").
		Where("id IN ?", cleanIDs).Find(&states).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询比赛状态失败"})
		return
	}

	foundIDs := make(map[uint]batchEventState, len(states))
	for _, st := range states {
		foundIDs[st.ID] = st
	}
	supersededIDs := make(map[uint]bool)
	if h.db.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
		var duplicateIDs []uint
		if err := h.db.Model(&models.CompetitionLegacyDuplicateResolution{}).
			Where("duplicate_event_id IN ?", cleanIDs).
			Pluck("duplicate_event_id", &duplicateIDs).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询赛事归并状态失败"})
			return
		}
		for _, id := range duplicateIDs {
			supersededIDs[id] = true
		}
	}

	var skipped []batchSkippedDetail
	var toUpdateIDs []uint
	var toDeleteIDs []uint
	var toVerifyIDs []uint
	newStatus := ""

	reasonCounts := make(map[string]int)

	for _, id := range cleanIDs {
		state, exists := foundIDs[id]
		if !exists {
			skipped = append(skipped, batchSkippedDetail{ID: id, Reason: "比赛不存在或已删除"})
			reasonCounts["比赛不存在或已删除"]++
			continue
		}
		readOnlyReason := ""
		switch {
		case state.CatalogPackageID != nil:
			readOnlyReason = "该赛事由活动目录包管理，只能通过目录修订修改"
		case supersededIDs[id]:
			readOnlyReason = "该赛事已被历史归并，不允许修改"
		case !strings.HasPrefix(state.CompetitionID, "MANUAL-"):
			readOnlyReason = "只有 MANUAL 赛事可通过旧管理入口修改"
		}
		if readOnlyReason != "" {
			skipped = append(skipped, batchSkippedDetail{ID: id, Reason: readOnlyReason})
			reasonCounts[readOnlyReason]++
			continue
		}

		if input.Action == "verify" {
			toVerifyIDs = append(toVerifyIDs, id)
			continue
		}

		targetStatus, err := checkEventStatusTransition(state.Status, input.Action)
		if err != nil {
			skipped = append(skipped, batchSkippedDetail{ID: id, Reason: err.Error()})
			reasonCounts[err.Error()]++
			continue
		}

		if input.Action == "delete" {
			toDeleteIDs = append(toDeleteIDs, id)
		} else {
			newStatus = targetStatus
			toUpdateIDs = append(toUpdateIDs, id)
		}
	}

	var skippedReasons []map[string]interface{}
	for reason, count := range reasonCounts {
		skippedReasons = append(skippedReasons, map[string]interface{}{
			"reason": reason, "count": count,
		})
	}

	if input.DryRun {
		c.JSON(http.StatusOK, gin.H{
			"matched_count":   totalMatched,
			"requested_count": len(cleanIDs),
			"success_count":   len(toUpdateIDs) + len(toDeleteIDs) + len(toVerifyIDs),
			"skipped_count":   len(skipped),
			"skipped_reasons": skippedReasons,
			"skipped":         skipped,
		})
		return
	}

	err := h.db.Transaction(func(tx *gorm.DB) error {
		if len(toDeleteIDs) > 0 {
			if err := tx.Model(&models.CompetitionEvent{}).Where("id IN ?", toDeleteIDs).UpdateColumn("updated_by", userID).Error; err != nil {
				return err
			}
			if err := tx.Where("id IN ?", toDeleteIDs).Delete(&models.CompetitionEvent{}).Error; err != nil {
				return err
			}
		}

		if len(toUpdateIDs) > 0 {
			updates := map[string]interface{}{"status": newStatus, "updated_by": userID}
			if newStatus == "archived" {
				now := time.Now()
				updates["archived_at"] = &now
			} else if newStatus == "draft" || newStatus == "published" {
				updates["archived_at"] = gorm.Expr("NULL")
			}
			if err := tx.Model(&models.CompetitionEvent{}).Where("id IN ?", toUpdateIDs).Updates(updates).Error; err != nil {
				return err
			}
		}

		if len(toVerifyIDs) > 0 {
			now := time.Now()
			if err := tx.Model(&models.CompetitionEvent{}).Where("id IN ?", toVerifyIDs).Updates(map[string]interface{}{
				"is_verified": true, "verified_by": userID, "verified_at": &now,
			}).Error; err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "批量操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"matched_count":   totalMatched,
		"requested_count": len(cleanIDs),
		"success_count":   len(toUpdateIDs) + len(toDeleteIDs) + len(toVerifyIDs),
		"skipped_count":   len(skipped),
		"skipped_reasons": skippedReasons,
		"skipped":         skipped,
	})
}

func (h *CompetitionHandler) adminBatchVerify(c *gin.Context, ids []uint, userID uint) error {
	now := time.Now()
	var events []models.CompetitionEvent
	if err := h.db.Where("id IN ?", ids).Find(&events).Error; err != nil {
		return fmt.Errorf("查询比赛失败")
	}

	foundIDs := make(map[uint]bool)
	var toVerifyIDs []uint
	var skipped []batchSkippedDetail
	for _, e := range events {
		foundIDs[e.ID] = true
		toVerifyIDs = append(toVerifyIDs, e.ID)
	}
	for _, id := range ids {
		if !foundIDs[id] {
			skipped = append(skipped, batchSkippedDetail{ID: id, Reason: "比赛不存在或已删除"})
		}
	}

	if len(toVerifyIDs) > 0 {
		if err := h.db.Model(&models.CompetitionEvent{}).Where("id IN ?", toVerifyIDs).Updates(map[string]interface{}{
			"is_verified": true, "verified_by": userID, "verified_at": &now,
		}).Error; err != nil {
			return fmt.Errorf("批量核验失败")
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"success_count": len(toVerifyIDs),
		"skipped_count": len(skipped),
		"skipped":       skipped,
	})
	return nil
}

func (h *CompetitionHandler) AdminGetEventsOverview(c *gin.Context) {
	now := time.Now()
	var total, draft, published, archived, timePending, stale, unverified int64

	base := h.db.Model(&models.CompetitionEvent{})
	base.Count(&total)
	base.Where("status = ?", "draft").Count(&draft)
	base.Where("status = ?", "published").Count(&published)
	base.Where("status = ?", "archived").Count(&archived)

	base.Where("registration_end IS NULL").
		Where("time_status IN ?", []string{"pending", "historical", "estimated"}).
		Count(&timePending)

	currentMonth := int(now.Month())
	nextMonth := int(now.AddDate(0, 1, 0).Month())
	base.Where("updated_at < ? OR (registration_end IS NULL AND sort_month IN ?)",
		now.AddDate(0, 0, -180), []int{currentMonth, nextMonth}).
		Count(&stale)

	base.Where("is_verified = ? OR time_status = ? OR school_recognition_status = ?", false, "pending", "pending").
		Count(&unverified)

	c.JSON(http.StatusOK, gin.H{
		"total": total, "draft": draft, "published": published, "archived": archived,
		"time_pending": timePending, "stale": stale, "unverified": unverified,
	})
}

func (h *CompetitionHandler) AdminVerifyEvent(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	if _, err := ensureCompetitionEventMutable(h.db, id); err != nil {
		if !respondCompetitionEventMutationError(c, err) {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "检查比赛治理状态失败"})
		}
		return
	}
	now := time.Now()
	if err := h.db.Model(&models.CompetitionEvent{}).Where("id = ?", id).Updates(map[string]interface{}{
		"is_verified": true, "verified_by": userID, "verified_at": &now,
	}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "核验失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已核验"})
}

func (h *CompetitionHandler) GetCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	calendar, err := h.ensureCalendar(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取日历失败"})
		return
	}
	var items []models.UserCompetitionCalendarItem
	h.db.Where("calendar_id = ?", calendar.ID).
		Order("is_pinned DESC").Order("display_order ASC").Order("sort_date ASC NULLS LAST").Find(&items)
	c.JSON(http.StatusOK, gin.H{"calendar": calendar, "items": items})
}

func (h *CompetitionHandler) InitCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	calendar, err := h.ensureCalendar(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "初始化日历失败"})
		return
	}
	c.JSON(http.StatusOK, calendar)
}

func (h *CompetitionHandler) ensureCalendar(userID uint) (models.UserCompetitionCalendar, error) {
	var calendar models.UserCompetitionCalendar
	err := h.db.Where("user_id = ?", userID).First(&calendar).Error
	if err == nil {
		return calendar, nil
	}
	if err != gorm.ErrRecordNotFound {
		return calendar, err
	}
	calendar = models.UserCompetitionCalendar{UserID: userID, Title: "我的竞赛计划", Visibility: "private"}
	if err := h.db.Create(&calendar).Error; err == nil {
		return calendar, nil
	}
	// 并发初始化时唯一索引可能由另一请求先占用，重新读取即可。
	if err := h.db.Where("user_id = ?", userID).First(&calendar).Error; err != nil {
		return calendar, err
	}
	return calendar, nil
}

func (h *CompetitionHandler) UpdateCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input struct{ Title, Description, Visibility string }
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if input.Visibility != "private" && input.Visibility != "public" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "visibility 必须为 private 或 public"})
		return
	}
	calendar, err := h.ensureCalendar(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取日历失败"})
		return
	}
	if result := h.db.Model(&models.UserCompetitionCalendar{}).Where("id = ?", calendar.ID).Updates(map[string]interface{}{
		"title": input.Title, "description": input.Description, "visibility": input.Visibility,
	}); result.Error != nil || result.RowsAffected != 1 {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新日历失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已更新"})
}

func (h *CompetitionHandler) DeleteCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var calendar models.UserCompetitionCalendar
		if err := tx.Where("user_id = ?", userID).First(&calendar).Error; err != nil {
			return err
		}
		if err := tx.Where("calendar_id = ?", calendar.ID).Delete(&models.UserCompetitionCalendarItem{}).Error; err != nil {
			return err
		}
		return tx.Delete(&calendar).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除日历失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

func (h *CompetitionHandler) CreateCalendarItem(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input competitionEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	event, err := h.eventFromInput(input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	calendar, err := h.ensureCalendar(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取日历失败"})
		return
	}
	item := calendarItemFromEvent(calendar.ID, userID, event, "manual", nil, "", nil)
	if err := applyCalendarPlanInput(&item, input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if err := h.db.Create(&item).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "新增比赛失败"})
		return
	}
	c.JSON(http.StatusCreated, item)
}

func (h *CompetitionHandler) CopyOfficialToCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	eventID, ok := parseUintParam(c, "event_id")
	if !ok {
		return
	}
	var responseItem models.UserCompetitionCalendarItem
	alreadyExists := false
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		var event models.CompetitionEvent
		if err := tx.First(&event, "id = ? AND status = ?", eventID, "published").Error; err != nil {
			return err
		}
		calendar, err := h.ensureCalendarTx(tx, userID)
		if err != nil {
			return err
		}
		item := calendarItemFromEvent(calendar.ID, userID, event, "official", &event.ID, "", nil)
		result := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&item)
		if result.Error != nil {
			return result.Error
		}
		if result.RowsAffected == 1 {
			responseItem = item
			return nil
		}
		alreadyExists = true
		return tx.Where("user_id = ? AND source_type = ? AND source_event_id = ?", userID, "official", event.ID).
			First(&responseItem).Error
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "加入我的计划失败"})
		return
	}
	status := http.StatusCreated
	if alreadyExists {
		status = http.StatusOK
	}
	c.JSON(status, gin.H{"already_exists": alreadyExists, "item": responseItem})
}

func (h *CompetitionHandler) ensureCalendarTx(tx *gorm.DB, userID uint) (models.UserCompetitionCalendar, error) {
	var calendar models.UserCompetitionCalendar
	err := tx.Where("user_id = ?", userID).First(&calendar).Error
	if err == nil {
		return calendar, nil
	}
	if err != gorm.ErrRecordNotFound {
		return calendar, err
	}
	calendar = models.UserCompetitionCalendar{UserID: userID, Title: "我的竞赛计划", Visibility: "private"}
	return calendar, tx.Create(&calendar).Error
}

func calendarItemFromEvent(calendarID, userID uint, event models.CompetitionEvent, sourceType string, sourceEventID *uint, shareCode string, snapshotID *uint) models.UserCompetitionCalendarItem {
	timePrecision := normalizeTimePrecision(event.TimePrecision)
	timeStatus := normalizeTimeStatus(event.TimeStatus)
	if event.RegistrationEnd != nil && strings.TrimSpace(event.TimePrecision) == "" {
		timePrecision = "exact"
	}
	if event.RegistrationEnd != nil && strings.TrimSpace(event.TimeStatus) == "" {
		timeStatus = "confirmed"
	}
	sortMonth := normalizeSortMonth(event.SortMonth)
	return models.UserCompetitionCalendarItem{
		CalendarID: calendarID, UserID: userID, Title: event.Title, Summary: event.Summary,
		Description: event.Description, CategoryID: event.PrimaryCategoryID, Tags: event.Tags,
		CompetitionLevel: event.CompetitionLevel, SchoolRecognitionStatus: event.SchoolRecognitionStatus,
		SchoolRecognitionGrade: event.SchoolRecognitionGrade, RecommendationLevel: event.RecommendationLevel,
		ImportanceScore: event.ImportanceScore, Organizer: event.Organizer, TargetAudience: event.TargetAudience,
		OfficialURL: event.OfficialURL, NoticeURL: event.NoticeURL, Location: event.Location, IsOnline: event.IsOnline,
		RegistrationStart: event.RegistrationStart, RegistrationEnd: event.RegistrationEnd,
		EventStart: event.EventStart, EventEnd: event.EventEnd,
		RegistrationTimeText: event.RegistrationTimeText, EventTimeText: event.EventTimeText,
		TimePrecision: timePrecision, TimeStatus: timeStatus, TimeNote: event.TimeNote,
		SortMonth: sortMonth, SortDate: event.SortDate, PlanStatus: "watching",
		SourceType: sourceType, SourceEventID: sourceEventID,
		SourceShareCode: shareCode, SourceSnapshotID: snapshotID, OriginalHash: eventHash(event),
	}
}

func eventHash(event models.CompetitionEvent) string {
	b, _ := json.Marshal([]interface{}{event.Title, event.OfficialURL, event.RegistrationEnd, event.EventStart, event.TimePrecision, event.TimeStatus, event.SortMonth})
	return hashJSON(b)
}

func applyCalendarPlanInput(item *models.UserCompetitionCalendarItem, input competitionEventInput) error {
	userDeadline, err := parseDatePtr(input.UserDeadline)
	if err != nil {
		return fmt.Errorf("用户提醒日期格式错误，应为 YYYY-MM-DD")
	}
	item.PlanStatus = normalizePlanStatus(input.PlanStatus)
	item.UserDeadline = userDeadline
	return nil
}

func (h *CompetitionHandler) UpdateCalendarItem(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input competitionEventInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	event, err := h.eventFromInput(input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	item := calendarItemFromEvent(0, userID, event, "", nil, "", nil)
	if err := applyCalendarPlanInput(&item, input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	item.IsCustomModified = true
	if err := h.db.Model(&models.UserCompetitionCalendarItem{}).
		Where("id = ? AND user_id = ?", id, userID).Updates(item).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新比赛失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已更新"})
}

func (h *CompetitionHandler) DeleteCalendarItem(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	if err := h.db.Where("id = ? AND user_id = ?", id, userID).Delete(&models.UserCompetitionCalendarItem{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除比赛失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已删除"})
}

func (h *CompetitionHandler) PinCalendarItem(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input struct {
		IsPinned bool `json:"is_pinned"`
	}
	_ = c.ShouldBindJSON(&input)
	if err := h.db.Model(&models.UserCompetitionCalendarItem{}).
		Where("id = ? AND user_id = ?", id, userID).Update("is_pinned", input.IsPinned).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "置顶失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已更新"})
}

func (h *CompetitionHandler) ReorderCalendarItems(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input struct {
		Items []struct {
			ID           uint `json:"id"`
			DisplayOrder int  `json:"display_order"`
		} `json:"items"`
	}
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		for _, item := range input.Items {
			if err := tx.Model(&models.UserCompetitionCalendarItem{}).
				Where("id = ? AND user_id = ?", item.ID, userID).
				Update("display_order", item.DisplayOrder).Error; err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "排序失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已排序"})
}

func (h *CompetitionHandler) ShareCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var snapshot models.CalendarShareSnapshot
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		calendar, err := h.ensureCalendarTx(tx, userID)
		if err != nil {
			return err
		}
		var items []models.UserCompetitionCalendarItem
		if err := tx.Where("calendar_id = ?", calendar.ID).Order("is_pinned DESC, display_order ASC, sort_date ASC NULLS LAST").Find(&items).Error; err != nil {
			return err
		}
		body := gin.H{"calendar": calendar, "items": items}
		raw, _ := json.Marshal(body)
		code := randomCode("CAMP", 4)
		snapshot = models.CalendarShareSnapshot{
			ShareCode: code, SnapshotHash: hashJSON(raw), SnapshotJSON: datatypes.JSON(raw),
			Version: 1, Title: calendar.Title, Description: calendar.Description,
			ItemCount: len(items), CreatedBy: userID, Status: "active",
		}
		return tx.Create(&snapshot).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成分享码失败"})
		return
	}
	c.JSON(http.StatusCreated, snapshot)
}

func (h *CompetitionHandler) RevokeShare(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	code := strings.TrimSpace(c.Param("share_code"))
	if err := h.db.Model(&models.CalendarShareSnapshot{}).
		Where("share_code = ? AND created_by = ?", code, userID).Update("status", "deleted").Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "撤销分享失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已撤销"})
}

func (h *CompetitionHandler) PreviewShareImport(c *gin.Context) {
	var input struct {
		ShareCode string `json:"share_code"`
	}
	_ = c.ShouldBindJSON(&input)
	snapshot, items, ok := h.loadShareSnapshot(c, input.ShareCode)
	if !ok {
		return
	}
	c.JSON(http.StatusOK, gin.H{"snapshot": snapshot, "items": items, "duplicate_count": 0})
}

func (h *CompetitionHandler) CommitShareImport(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input struct {
		ShareCode string `json:"share_code"`
		Strategy  string `json:"strategy"`
	}
	_ = c.ShouldBindJSON(&input)
	if input.Strategy != "replace" && input.Strategy != "merge" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "导入策略只能是 replace 或 merge"})
		return
	}
	snapshot, items, ok := h.loadShareSnapshot(c, input.ShareCode)
	if !ok {
		return
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		calendar, err := h.ensureCalendarTx(tx, userID)
		if err != nil {
			return err
		}
		if input.Strategy == "replace" {
			if err := tx.Where("calendar_id = ?", calendar.ID).Delete(&models.UserCompetitionCalendarItem{}).Error; err != nil {
				return err
			}
		}
		for _, source := range items {
			var count int64
			tx.Model(&models.UserCompetitionCalendarItem{}).Where("calendar_id = ? AND title = ? AND official_url = ?", calendar.ID, source.Title, source.OfficialURL).Count(&count)
			if input.Strategy == "merge" && count > 0 {
				continue
			}
			source.ID = 0
			source.CalendarID = calendar.ID
			source.UserID = userID
			source.SourceType = "share"
			source.SourceShareCode = snapshot.ShareCode
			source.SourceSnapshotID = &snapshot.ID
			if err := tx.Create(&source).Error; err != nil {
				return err
			}
		}
		now := time.Now()
		return tx.Model(&snapshot).Updates(map[string]interface{}{
			"import_count": gorm.Expr("import_count + 1"), "last_imported_at": &now,
		}).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "导入分享失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "导入完成"})
}

func (h *CompetitionHandler) PreviewCalendarJSONImport(c *gin.Context) {
	var payload map[string]interface{}
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "JSON 格式错误"})
		return
	}

	result := h.validateImportPayload(payload)
	c.JSON(http.StatusOK, gin.H{"preview": result})
}

func (h *CompetitionHandler) CommitCalendarJSONImport(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}

	var input struct {
		Strategy string                  `json:"strategy"`
		Events   []competitionEventInput `json:"events"`
	}

	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	if input.Strategy != "replace" && input.Strategy != "merge" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "导入策略只能是 replace 或 merge"})
		return
	}

	if len(input.Events) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "events 不能为空"})
		return
	}

	created := 0

	if err := h.db.Transaction(func(tx *gorm.DB) error {
		calendar, err := h.ensureCalendarTx(tx, userID)
		if err != nil {
			return err
		}

		if input.Strategy == "replace" {
			if err := tx.Where("calendar_id = ?", calendar.ID).
				Delete(&models.UserCompetitionCalendarItem{}).Error; err != nil {
				return err
			}
		}

		for i, eventInput := range input.Events {
			event, err := h.eventFromInput(eventInput)
			if err != nil {
				return err
			}

			if input.Strategy == "merge" {
				var count int64
				tx.Model(&models.UserCompetitionCalendarItem{}).
					Where(
						"calendar_id = ? AND title = ? AND official_url = ?",
						calendar.ID,
						event.Title,
						event.OfficialURL,
					).
					Count(&count)
				if count > 0 {
					continue
				}
			}

			item := calendarItemFromEvent(
				calendar.ID,
				userID,
				event,
				"local_json",
				nil,
				"",
				nil,
			)
			item.IsCustomModified = true
			item.DisplayOrder = i

			if err := tx.Create(&item).Error; err != nil {
				return err
			}
			created++
		}

		return nil
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "导入失败：" + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message": "导入完成",
		"created": created,
	})
}

func (h *CompetitionHandler) loadShareSnapshot(c *gin.Context, code string) (models.CalendarShareSnapshot, []models.UserCompetitionCalendarItem, bool) {
	var snapshot models.CalendarShareSnapshot
	if err := h.db.Where("share_code = ?", strings.TrimSpace(code)).First(&snapshot).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "分享码不存在"})
		return snapshot, nil, false
	}
	if snapshot.Status != "active" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "分享码不可导入"})
		return snapshot, nil, false
	}
	var payload struct {
		Items []models.UserCompetitionCalendarItem `json:"items"`
	}
	if err := json.Unmarshal(snapshot.SnapshotJSON, &payload); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "分享快照损坏"})
		return snapshot, nil, false
	}
	return snapshot, payload.Items, true
}

func (h *CompetitionHandler) AdminListShareSnapshots(c *gin.Context) {
	var items []models.CalendarShareSnapshot
	if err := h.db.Order("created_at DESC").Limit(200).Find(&items).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取分享码失败"})
		return
	}
	c.JSON(http.StatusOK, items)
}

func (h *CompetitionHandler) AdminDisableShareSnapshot(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	var input struct {
		Reason string `json:"reason"`
	}
	_ = c.ShouldBindJSON(&input)
	if err := h.db.Model(&models.CalendarShareSnapshot{}).Where("id = ?", id).
		Updates(map[string]interface{}{"status": "disabled", "disabled_reason": input.Reason}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "禁用失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已禁用"})
}

func (h *CompetitionHandler) AdminRestoreShareSnapshot(c *gin.Context) {
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	if err := h.db.Model(&models.CalendarShareSnapshot{}).Where("id = ?", id).
		Updates(map[string]interface{}{"status": "active", "disabled_reason": ""}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已恢复"})
}

func (h *CompetitionHandler) AdminImportJSONPreview(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var payload map[string]interface{}
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "JSON 格式错误"})
		return
	}
	raw, _ := json.Marshal(payload)
	normalizedPayload, result := h.normalizeImportPayload(payload)
	normalizedRaw, _ := json.Marshal(normalizedPayload)
	batch := models.CompetitionImportBatch{
		BatchID: randomCode("BATCH", 8), UserID: userID, SourceType: "ai_import",
		RawPayload: datatypes.JSON(raw), NormalizedPayload: datatypes.JSON(normalizedRaw),
		PayloadSize: len(raw), Status: "previewed", ExpiresAt: time.Now().Add(24 * time.Hour),
		ItemCount: result["item_count"].(int), ValidCount: result["valid_count"].(int),
		ErrorCount: len(result["errors"].([]gin.H)),
	}
	errRaw, _ := json.Marshal(result)
	batch.ErrorSummary = datatypes.JSON(errRaw)
	if err := h.db.Create(&batch).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建导入批次失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"batch_id": batch.BatchID, "preview": result})
}

func (h *CompetitionHandler) validateImportPayload(payload map[string]interface{}) gin.H {
	_, result := h.normalizeImportPayload(payload)
	return result
}

func stringArrayFromImportField(value interface{}) ([]string, bool) {
	if value == nil {
		return []string{}, true
	}
	rawValues, ok := value.([]interface{})
	if !ok {
		if typed, typedOK := value.([]string); typedOK {
			return typed, true
		}
		return nil, false
	}
	values := make([]string, 0, len(rawValues))
	for _, raw := range rawValues {
		value, ok := raw.(string)
		if !ok {
			return nil, false
		}
		values = append(values, value)
	}
	return values, true
}

func importString(item map[string]interface{}, key string) string {
	value, exists := item[key]
	if !exists || value == nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprint(value))
}

func (h *CompetitionHandler) normalizeImportPayload(payload map[string]interface{}) (map[string]interface{}, gin.H) {
	errors := []gin.H{}
	warnings := []gin.H{}
	events, _ := payload["events"].([]interface{})
	if len(events) == 0 {
		errors = append(errors, gin.H{"index": -1, "field": "events", "message": "events 不能为空"})
	}
	validCount := 0
	normalizedEvents := make([]interface{}, 0, len(events))
	for i, raw := range events {
		item, _ := raw.(map[string]interface{})
		normalized := make(map[string]interface{}, len(item))
		for key, value := range item {
			normalized[key] = value
		}
		hasError := false
		title := importString(item, "title")
		normalized["title"] = title
		if title == "" {
			errors = append(errors, gin.H{"index": i, "field": "title", "message": "标题不能为空"})
			hasError = true
		}
		slug := importString(item, "primary_category_slug")
		var count int64
		h.db.Model(&models.CompetitionCategory{}).Where("slug = ?", slug).Count(&count)
		if count == 0 {
			errors = append(errors, gin.H{"index": i, "field": "primary_category_slug", "message": "分类不存在：" + slug})
			hasError = true
		}
		for _, field := range []string{"official_url", "notice_url"} {
			value := importString(item, field)
			normalized[field] = value
			if !validURL(value) {
				errors = append(errors, gin.H{"index": i, "field": field, "message": "URL 必须是 http/https"})
				hasError = true
			}
		}
		parsedDates := map[string]*time.Time{}
		for _, field := range []string{"registration_start", "registration_end", "event_start", "event_end"} {
			value := importString(item, field)
			normalized[field] = value
			parsed, err := parseDatePtr(value)
			if err != nil {
				errors = append(errors, gin.H{"index": i, "field": field, "message": "日期格式应为 YYYY-MM-DD"})
				hasError = true
				continue
			}
			parsedDates[field] = parsed
		}
		if start, end := parsedDates["registration_start"], parsedDates["registration_end"]; start != nil && end != nil && end.Before(*start) {
			errors = append(errors, gin.H{"index": i, "field": "registration_end", "message": "报名截止不能早于报名开始"})
			hasError = true
		}
		if start, end := parsedDates["event_start"], parsedDates["event_end"]; start != nil && end != nil && end.Before(*start) {
			errors = append(errors, gin.H{"index": i, "field": "event_end", "message": "比赛结束不能早于比赛开始"})
			hasError = true
		}
		if importString(item, "registration_end") == "" &&
			importString(item, "event_start") == "" &&
			importString(item, "time_note") == "" {
			warnings = append(warnings, gin.H{"index": i, "field": "time_note", "message": "时间为空时建议说明来源"})
		}
		if importString(item, "school_recognition_status") == "recognized" &&
			importString(item, "source_note") == "" {
			warnings = append(warnings, gin.H{"index": i, "field": "source_note", "message": "学校认定为已认定时建议填写来源说明"})
		}
		ratingInput := importString(item, "competition_rating")
		if ratingInput == "" {
			ratingInput = importString(item, "recommendation_level")
		}
		recommendation, recommendationErr := normalizeRecommendationLevel(ratingInput)
		if recommendationErr != nil {
			errors = append(errors, gin.H{"index": i, "field": "competition_rating", "message": recommendationErr.Error()})
			hasError = true
		} else {
			normalized["competition_rating"] = recommendation
			normalized["recommendation_level"] = recommendation
		}
		entryYears, entryYearsOK := stringArrayFromImportField(item["eligible_entry_years"])
		if !entryYearsOK {
			errors = append(errors, gin.H{"index": i, "field": "eligible_entry_years", "message": "必须是字符串数组"})
			hasError = true
			entryYears = []string{}
		}
		normalizedEntryYears, entryYearsErr := normalizeEntryYears(entryYears, time.Now())
		if entryYearsErr != nil {
			errors = append(errors, gin.H{"index": i, "field": "eligible_entry_years", "message": entryYearsErr.Error()})
			hasError = true
			normalizedEntryYears = []string{}
		}
		colleges, collegesOK := stringArrayFromImportField(item["eligible_colleges"])
		if !collegesOK {
			errors = append(errors, gin.H{"index": i, "field": "eligible_colleges", "message": "必须是字符串数组"})
			hasError = true
			colleges = []string{}
		}
		majors, majorsOK := stringArrayFromImportField(item["eligible_majors"])
		if !majorsOK {
			errors = append(errors, gin.H{"index": i, "field": "eligible_majors", "message": "必须是字符串数组"})
			hasError = true
			majors = []string{}
		}
		normalizedColleges := normalizeStringValues(colleges, normalizeAcademicName)
		normalizedMajors := normalizeStringValues(majors, normalizeAcademicName)
		normalized["eligible_entry_years"] = normalizedEntryYears
		normalized["eligible_colleges"] = normalizedColleges
		normalized["eligible_majors"] = normalizedMajors
		if len(normalizedEntryYears) == 0 && len(normalizedColleges) == 0 && len(normalizedMajors) == 0 {
			warnings = append(warnings, gin.H{"index": i, "field": "eligible_entry_years", "message": "适用范围为空，将按通用比赛处理"})
		}
		if !hasError {
			validCount++
		}
		normalizedEvents = append(normalizedEvents, normalized)
	}
	normalizedPayload := make(map[string]interface{}, len(payload))
	for key, value := range payload {
		normalizedPayload[key] = value
	}
	normalizedPayload["events"] = normalizedEvents
	result := gin.H{"item_count": len(events), "valid_count": validCount, "errors": errors, "warnings": warnings, "items": normalizedEvents}
	return normalizedPayload, result
}

func (h *CompetitionHandler) AdminImportJSONCommit(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input struct {
		BatchID string `json:"batch_id"`
		Actions []struct {
			Index   uint   `json:"index"`
			Action  string `json:"action"`
			EventID uint   `json:"event_id"`
		} `json:"selected_actions"`
	}
	if err := c.ShouldBindJSON(&input); err != nil || input.BatchID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "必须提交 batch_id 和 selected_actions"})
		return
	}
	var batch models.CompetitionImportBatch
	if err := h.db.Where("batch_id = ? AND user_id = ? AND status = ? AND expires_at > ?", input.BatchID, userID, "previewed", time.Now()).First(&batch).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "导入批次不存在或已提交"})
		return
	}
	var payload struct {
		Events []competitionEventInput `json:"events"`
	}
	if err := json.Unmarshal(batch.NormalizedPayload, &payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "批次数据损坏"})
		return
	}
	var validationSummary struct {
		Errors []struct {
			Index int `json:"index"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(batch.ErrorSummary, &validationSummary); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "批次校验结果损坏"})
		return
	}
	invalidIndexes := make(map[uint]struct{}, len(validationSummary.Errors))
	for _, itemError := range validationSummary.Errors {
		if itemError.Index >= 0 {
			invalidIndexes[uint(itemError.Index)] = struct{}{}
		}
	}
	actionMap := map[uint]string{}
	for _, action := range input.Actions {
		if int(action.Index) >= len(payload.Events) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "selected_actions 包含越界条目"})
			return
		}
		if action.Action != "create" && action.Action != "skip" && action.Action != "manual_review" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "不支持的导入动作"})
			return
		}
		if action.Action == "create" {
			if _, invalid := invalidIndexes[action.Index]; invalid {
				c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("第 %d 条存在校验错误，不能提交", action.Index+1)})
				return
			}
		}
		actionMap[action.Index] = action.Action
	}
	created := 0
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		for i, eventInput := range payload.Events {
			action := actionMap[uint(i)]
			if action == "" || action == "skip" || action == "manual_review" {
				continue
			}
			event, err := h.eventFromInput(eventInput)
			if err != nil {
				return err
			}
			event.SourceChannel = "ai_import"
			event.Status = "draft"
			event.CreatedBy = userID
			event.UpdatedBy = userID
			if action == "create" {
				if err := tx.Create(&event).Error; err != nil {
					return err
				}
				created++
			}
		}
		now := time.Now()
		return tx.Model(&batch).Updates(map[string]interface{}{"status": "committed", "committed_at": &now}).Error
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "提交导入失败：" + err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "导入完成", "created": created})
}

func (h *CompetitionHandler) AdminListImportBatches(c *gin.Context) {
	var batches []models.CompetitionImportBatch
	if err := h.db.Order("created_at DESC").Limit(100).Find(&batches).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取导入批次失败"})
		return
	}
	c.JSON(http.StatusOK, batches)
}

func (h *CompetitionHandler) AdminGetImportBatch(c *gin.Context) {
	batchID := c.Param("batch_id")
	var batch models.CompetitionImportBatch
	if err := h.db.Where("batch_id = ?", batchID).First(&batch).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "批次不存在"})
		return
	}
	c.JSON(http.StatusOK, batch)
}

type batchCalendarItemActionInput struct {
	IDs        []uint `json:"ids"`
	Action     string `json:"action"`
	PlanStatus string `json:"plan_status,omitempty"`
}

func (h *CompetitionHandler) BatchCalendarItemAction(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input batchCalendarItemActionInput
	if err := c.ShouldBindJSON(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if len(input.IDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请选择计划项目"})
		return
	}

	uniqueIDs := make(map[uint]struct{}, len(input.IDs))
	var cleanIDs []uint
	for _, id := range input.IDs {
		if _, exists := uniqueIDs[id]; !exists {
			uniqueIDs[id] = struct{}{}
			cleanIDs = append(cleanIDs, id)
		}
	}
	if len(cleanIDs) > 1000 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次最多批量操作 1000 项"})
		return
	}

	var items []models.UserCompetitionCalendarItem
	if err := h.db.Where("id IN ? AND user_id = ?", cleanIDs, userID).Find(&items).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询计划项目失败"})
		return
	}

	foundIDs := make(map[uint]bool)
	for _, it := range items {
		foundIDs[it.ID] = true
	}

	var skipped []batchSkippedDetail
	var toUpdateIDs []uint
	var toDeleteIDs []uint
	newStatus := ""

	for _, id := range cleanIDs {
		if !foundIDs[id] {
			skipped = append(skipped, batchSkippedDetail{ID: id, Reason: "项目不存在或无权限"})
			continue
		}

		switch input.Action {
		case "set_plan_status":
			validStatuses := map[string]bool{"watching": true, "preparing": true, "registered": true, "submitted": true, "finished": true, "archived": true}
			if !validStatuses[input.PlanStatus] {
				skipped = append(skipped, batchSkippedDetail{ID: id, Reason: "无效的计划状态"})
				continue
			}
			newStatus = input.PlanStatus
			toUpdateIDs = append(toUpdateIDs, id)
		case "archive":
			newStatus = "archived"
			toUpdateIDs = append(toUpdateIDs, id)
		case "restore":
			newStatus = "watching"
			toUpdateIDs = append(toUpdateIDs, id)
		case "delete":
			toDeleteIDs = append(toDeleteIDs, id)
		default:
			skipped = append(skipped, batchSkippedDetail{ID: id, Reason: "未知的操作"})
		}
	}

	err := h.db.Transaction(func(tx *gorm.DB) error {
		if len(toDeleteIDs) > 0 {
			if err := tx.Where("id IN ?", toDeleteIDs).Delete(&models.UserCompetitionCalendarItem{}).Error; err != nil {
				return err
			}
		}

		if len(toUpdateIDs) > 0 {
			updates := map[string]interface{}{"plan_status": newStatus, "is_custom_modified": true}
			if err := tx.Model(&models.UserCompetitionCalendarItem{}).Where("id IN ?", toUpdateIDs).Updates(updates).Error; err != nil {
				return err
			}
		}
		return nil
	})

	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "批量操作失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success_count": len(toUpdateIDs) + len(toDeleteIDs),
		"skipped_count": len(skipped),
		"skipped":       skipped,
	})
}
