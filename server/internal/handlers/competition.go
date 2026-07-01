package handlers

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type CompetitionHandler struct {
	db *gorm.DB
}

func NewCompetitionHandler(db *gorm.DB) *CompetitionHandler {
	return &CompetitionHandler{db: db}
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
	RecommendationLevel     string   `json:"recommendation_level"`
	ImportanceScore         int      `json:"importance_score"`
	RecommendationReason    string   `json:"recommendation_reason"`
	IsFeatured              bool     `json:"is_featured"`
	IsVerified              bool     `json:"is_verified"`
	Organizer               string   `json:"organizer"`
	HostUnit                string   `json:"host_unit"`
	UndertakeUnit           string   `json:"undertake_unit"`
	TargetAudience          string   `json:"target_audience"`
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

func (h *CompetitionHandler) ListEvents(c *gin.Context) {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	if page < 1 {
		page = 1
	}
	if pageSize < 1 || pageSize > 50 {
		pageSize = 20
	}
	query := h.db.Model(&models.CompetitionEvent{}).Preload("PrimaryCategory").
		Where("status = ?", "published")
	query = h.applyEventFilters(c, query)

	var total int64
	query.Count(&total)
	var events []models.CompetitionEvent
	if err := query.Order("sort_date ASC NULLS LAST").Order("importance_score DESC").
		Offset((page - 1) * pageSize).Limit(pageSize).Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取比赛列表失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": events, "total": total, "page": page, "page_size": pageSize})
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
	for _, key := range []string{"school_recognition_status", "school_recognition_grade", "recommendation_level", "source_channel", "competition_level", "time_status", "time_precision"} {
		if value := strings.TrimSpace(c.Query(key)); value != "" {
			query = query.Where(key+" IN ?", strings.Split(value, ","))
		}
	}
	if c.Query("is_featured") != "" {
		query = query.Where("is_featured = ?", c.Query("is_featured") == "true")
	}
	if c.Query("is_online") != "" {
		query = query.Where("is_online = ?", c.Query("is_online") == "true")
	}
	switch c.Query("date_status") {
	case "deadline_soon":
		query = query.Where("registration_end IS NOT NULL AND registration_end BETWEEN ? AND ?", time.Now(), time.Now().AddDate(0, 0, 14))
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
	var event models.CompetitionEvent
	if err := h.db.Preload("PrimaryCategory").First(&event, "id = ? AND status = ?", id, "published").Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "比赛不存在"})
		return
	}
	c.JSON(http.StatusOK, event)
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
	if err := h.db.Model(&models.CompetitionCategory{}).Where("id = ?", id).Update("is_active", false).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除分类失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已停用分类"})
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
	query := h.db.Model(&models.CompetitionEvent{}).Preload("PrimaryCategory")
	if status := strings.TrimSpace(c.Query("status")); status != "" && status != "all" {
		query = query.Where("status = ?", status)
	}
	query = h.applyMaintenanceFilters(c, query)
	query = h.applyEventFilters(c, query)
	var total int64
	query.Count(&total)
	var events []models.CompetitionEvent
	if err := query.Order("updated_at DESC").Offset((page - 1) * pageSize).Limit(pageSize).Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取比赛失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": events, "total": total})
}

func (h *CompetitionHandler) applyMaintenanceFilters(c *gin.Context, query *gorm.DB) *gorm.DB {
	now := time.Now()
	switch strings.TrimSpace(c.Query("maintenance_status")) {
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
	c.JSON(http.StatusCreated, event)
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
	if err := h.db.Model(&models.CompetitionEvent{}).Where("id = ?", id).Updates(event).Error; err != nil {
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
	sortMonth := normalizeSortMonth(input.SortMonth)
	timePrecision := normalizeTimePrecision(input.TimePrecision)
	timeStatus := normalizeTimeStatus(input.TimeStatus)
	if regEnd != nil && strings.TrimSpace(input.TimePrecision) == "" {
		timePrecision = "exact"
	}
	if regEnd != nil && strings.TrimSpace(input.TimeStatus) == "" {
		timeStatus = "confirmed"
	}
	return models.CompetitionEvent{
		Title: input.Title, Subtitle: input.Subtitle, Summary: input.Summary, Description: input.Description,
		PrimaryCategoryID: categoryID, Tags: jsonArray(input.Tags), CompetitionLevel: input.CompetitionLevel,
		SchoolRecognitionStatus: input.SchoolRecognitionStatus, SchoolRecognitionGrade: input.SchoolRecognitionGrade,
		RecommendationLevel: input.RecommendationLevel, ImportanceScore: input.ImportanceScore,
		RecommendationReason: input.RecommendationReason, IsFeatured: input.IsFeatured, IsVerified: input.IsVerified,
		Organizer: input.Organizer, HostUnit: input.HostUnit, UndertakeUnit: input.UndertakeUnit,
		TargetAudience: input.TargetAudience, ParticipationType: input.ParticipationType,
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
	h.adminSetEventStatus(c, "archived")
}

func (h *CompetitionHandler) AdminPublishEvent(c *gin.Context) {
	h.adminSetEventStatus(c, "published")
}

func (h *CompetitionHandler) AdminDeleteEvent(c *gin.Context) {
	h.adminSetEventStatus(c, "archived")
}

func (h *CompetitionHandler) adminSetEventStatus(c *gin.Context, status string) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	id, ok := parseUintParam(c, "id")
	if !ok {
		return
	}
	updates := map[string]interface{}{"status": status, "updated_by": userID}
	if status == "archived" {
		now := time.Now()
		updates["archived_at"] = &now
	}
	if err := h.db.Model(&models.CompetitionEvent{}).Where("id = ?", id).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新比赛状态失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "已更新状态"})
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
	return calendar, h.db.Create(&calendar).Error
}

func (h *CompetitionHandler) UpdateCalendar(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input struct{ Title, Description, Visibility string }
	_ = c.ShouldBindJSON(&input)
	if err := h.db.Model(&models.UserCompetitionCalendar{}).Where("user_id = ?", userID).Updates(map[string]interface{}{
		"title": input.Title, "description": input.Description, "visibility": input.Visibility,
	}).Error; err != nil {
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
		return tx.Create(&item).Error
	}); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "加入我的计划失败"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"message": "已加入我的计划"})
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
	result := h.validateImportPayload(payload)
	batch := models.CompetitionImportBatch{
		BatchID: randomCode("BATCH", 8), UserID: userID, SourceType: "ai_import",
		RawPayload: datatypes.JSON(raw), NormalizedPayload: datatypes.JSON(raw),
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
	errors := []gin.H{}
	warnings := []gin.H{}
	events, _ := payload["events"].([]interface{})
	if len(events) == 0 {
		errors = append(errors, gin.H{"index": -1, "field": "events", "message": "events 不能为空"})
	}
	validCount := 0
	for i, raw := range events {
		item, _ := raw.(map[string]interface{})
		hasError := false
		if strings.TrimSpace(fmt.Sprint(item["title"])) == "" {
			errors = append(errors, gin.H{"index": i, "field": "title", "message": "标题不能为空"})
			hasError = true
		}
		slug := strings.TrimSpace(fmt.Sprint(item["primary_category_slug"]))
		var count int64
		h.db.Model(&models.CompetitionCategory{}).Where("slug = ?", slug).Count(&count)
		if count == 0 {
			errors = append(errors, gin.H{"index": i, "field": "primary_category_slug", "message": "分类不存在：" + slug})
			hasError = true
		}
		for _, field := range []string{"official_url", "notice_url"} {
			if !validURL(strings.TrimSpace(fmt.Sprint(item[field]))) {
				errors = append(errors, gin.H{"index": i, "field": field, "message": "URL 必须是 http/https"})
				hasError = true
			}
		}
		if strings.TrimSpace(fmt.Sprint(item["registration_end"])) == "" &&
			strings.TrimSpace(fmt.Sprint(item["event_start"])) == "" &&
			strings.TrimSpace(fmt.Sprint(item["time_note"])) == "" {
			warnings = append(warnings, gin.H{"index": i, "field": "time_note", "message": "时间为空时建议说明来源"})
		}
		if strings.TrimSpace(fmt.Sprint(item["school_recognition_status"])) == "recognized" &&
			strings.TrimSpace(fmt.Sprint(item["source_note"])) == "" {
			warnings = append(warnings, gin.H{"index": i, "field": "source_note", "message": "学校认定为已认定时建议填写来源说明"})
		}
		if !hasError {
			validCount++
		}
	}
	return gin.H{"item_count": len(events), "valid_count": validCount, "errors": errors, "warnings": warnings}
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
	if err := h.db.Where("batch_id = ? AND status = ?", input.BatchID, "previewed").First(&batch).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "导入批次不存在或已提交"})
		return
	}
	var payload struct {
		Events []competitionEventInput `json:"events"`
	}
	if err := json.Unmarshal(batch.RawPayload, &payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "批次数据损坏"})
		return
	}
	actionMap := map[uint]string{}
	for _, action := range input.Actions {
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
