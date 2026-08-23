package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/models"
)

const campusMCPToolVersion = "2026-08-22"

// CampusToolResult 是校园 MCP 对模型返回的统一结果信封。
// 它只携带语义化结果及来源证据，绝不返回数据库、凭据或爬虫细节。
type CampusToolResult struct {
	Data      interface{}          `json:"data"`
	Status    academic.DataStatus  `json:"status"`
	Source    academic.DataSource  `json:"source"`
	FetchedAt *time.Time           `json:"fetched_at,omitempty"`
	ExpiresAt *time.Time           `json:"expires_at,omitempty"`
	IsStale   bool                 `json:"is_stale"`
	IsPartial bool                 `json:"is_partial"`
	Warnings  []string             `json:"warnings"`
	Evidence  []CampusToolEvidence `json:"evidence"`
}

// CampusToolEvidence 提供给回答证据区的公开或已授权来源信息。
type CampusToolEvidence struct {
	Source    academic.DataSource  `json:"source"`
	Title     string               `json:"title"`
	URL       string               `json:"url,omitempty"`
	Dataset   academic.DatasetType `json:"dataset,omitempty"`
	FetchedAt *time.Time           `json:"fetched_at,omitempty"`
	ExpiresAt *time.Time           `json:"expires_at,omitempty"`
	IsStale   bool                 `json:"is_stale"`
}

type campusMCPTool struct {
	name        string
	description string
	parameters  map[string]interface{}
	execute     func(context.Context, uint, json.RawMessage) (interface{}, error)
}

func (tool campusMCPTool) Name() string    { return tool.name }
func (tool campusMCPTool) Version() string { return campusMCPToolVersion }
func (tool campusMCPTool) Definition() ToolDefinition {
	return ToolDefinition{Name: tool.name, Description: tool.description, Parameters: tool.parameters}
}
func (tool campusMCPTool) Execute(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	return tool.execute(ctx, userID, arguments)
}

type campusMCP struct {
	db                *gorm.DB
	policyRetriever   PolicyRetriever
	snapshots         AcademicSnapshotReader
	personalSnapshots PersonalSnapshotReader
	deviceJobs        DeviceJobScheduler
	permissions       PersonalDataPermissionReader
	now               func() time.Time
}

// DeviceJobRequest 是 MCP 请求本地加密缓存时的最小服务端契约。
// 它不包含设备密钥、推送正文或任何个人数据结果。
type DeviceJobRequest struct {
	UserID            uint
	RunID             string
	ToolCallID        string
	ToolName          string
	Arguments         json.RawMessage
	RequiredDataTypes []string
	ExpiresAt         time.Time
}

type DeviceJobReference struct {
	ID string
}

// DeviceJobScheduler 由应用装配层实现，避免 MCP 依赖设备服务的具体存储实现。
type DeviceJobScheduler interface {
	ScheduleDeviceJob(context.Context, DeviceJobRequest) (DeviceJobReference, error)
}

type DeviceJobSchedulerFunc func(context.Context, DeviceJobRequest) (DeviceJobReference, error)

func (fn DeviceJobSchedulerFunc) ScheduleDeviceJob(ctx context.Context, request DeviceJobRequest) (DeviceJobReference, error) {
	return fn(ctx, request)
}

type CampusMCPOption func(*campusMCP)

// WithCampusPolicyRetriever 让政策工具与 Runtime 复用同一套混合检索实现。
func WithCampusPolicyRetriever(retriever PolicyRetriever) CampusMCPOption {
	return func(mcp *campusMCP) { mcp.policyRetriever = retriever }
}

// WithCampusDeviceJobScheduler 启用“服务端快照未命中时请求手机缓存”的受控降级。
func WithCampusDeviceJobScheduler(scheduler DeviceJobScheduler) CampusMCPOption {
	return func(mcp *campusMCP) { mcp.deviceJobs = scheduler }
}

// PersonalDataPermissionReader 读取用户设置的长期个人数据访问偏好。
// ask 保持逐次确认，never 必须在创建设备任务或读取云端快照前失败关闭。
type PersonalDataPermissionReader interface {
	Policy(context.Context, uint, models.AIUserPermissionScope) (models.AIUserPermissionPolicy, error)
}

// WithCampusPersonalDataPermissionReader 接入服务端持久化权限策略。
func WithCampusPersonalDataPermissionReader(reader PersonalDataPermissionReader) CampusMCPOption {
	return func(mcp *campusMCP) { mcp.permissions = reader }
}

// AcademicSnapshotReader 是校园 Agent 读取已授权学业快照所需的最小能力。
// 身份与授权代次由实现校验，MCP 不读取数据库载荷或凭据。
type AcademicSnapshotReader interface {
	CurrentCredentialGeneration(context.Context, uint) (uint, error)
	LookupLatest(context.Context, uint, academic.DatasetType, uint) (academic.SnapshotLookup, error)
}

// PersonalSnapshotReader 只暴露用户主动上传的二课结构化快照读取能力。
// 它不提供二课凭据、设备缓存或原始页面访问。
type PersonalSnapshotReader interface {
	LookupErke(context.Context, uint) (academic.SnapshotLookup, error)
}

// NewCampusMCPTools 创建服务器校园 Agent 唯一可见的语义工具白名单。
// 底层查询、设备、Cookie、HTTP 和密码能力均不会注册为工具。
func NewCampusMCPTools(db *gorm.DB, snapshots AcademicSnapshotReader, personalSnapshots PersonalSnapshotReader, options ...CampusMCPOption) []PureReadTool {
	mcp := &campusMCP{db: db, snapshots: snapshots, personalSnapshots: personalSnapshots, now: time.Now}
	for _, option := range options {
		if option != nil {
			option(mcp)
		}
	}
	return []PureReadTool{
		campusMCPTool{"campus.search_policy", "检索已发布的学校政策、办事规则与知识库资料。", searchSchema(), mcp.searchPolicy},
		campusMCPTool{"campus.search_service", "检索校园服务办理信息与服务说明。", searchSchema(), mcp.searchService},
		campusMCPTool{"campus.search_notifications", "检索已发布的教务、创新创业和站内公告。", searchSchema(), mcp.searchNotifications},
		campusMCPTool{"campus.get_term_info", "读取当前或指定学年的已发布校历与教学周信息。", termSchema(), mcp.getTermInfo},
		campusMCPTool{"calendar.get_day", "读取指定日期的校历语义：学期、教学周、调休和校历事件。", calendarDaySchema(), mcp.getCalendarDay},
		campusMCPTool{"calendar.get_range", "读取日期范围内的官方校历语义，最多 31 天。", calendarRangeSchema(), mcp.getCalendarRange},
		campusMCPTool{"calendar.get_current_term", "读取当前已发布校历的学期与教学周配置。", emptySchema(), mcp.getCurrentTerm},
		campusMCPTool{"calendar.get_teaching_week", "读取指定日期对应的教学周和调休信息。", calendarDaySchema(), mcp.getTeachingWeek},
		campusMCPTool{"canteen.search", "检索已审核且当前营业的食堂与菜品。", canteenSearchSchema(), mcp.searchCanteens},
		campusMCPTool{"canteen.get_details", "读取一个已审核食堂的公开信息和在售菜品。", canteenIDSchema(), mcp.getCanteenDetails},
		campusMCPTool{"canteen.search_dishes", "检索当前营业食堂中的公开在售菜品。", dishSearchSchema(), mcp.searchDishes},
		campusMCPTool{"canteen.get_dish_details", "读取一个公开在售菜品及其安全评分摘要。", dishIDSchema(), mcp.getDishDetails},
		campusMCPTool{"canteen.get_rankings", "读取当前营业食堂的公开评分排行。", rankingSchema(), mcp.getCanteenRankings},
		campusMCPTool{"canteen.get_recent_reviews", "读取当前营业食堂的近期公开评价摘要。", recentReviewsSchema(), mcp.getRecentCanteenReviews},
		campusMCPTool{"competition.search_catalog", "按关键词检索当前公开赛事目录。", competitionSearchSchema(), mcp.searchCompetitionCatalog},
		campusMCPTool{"competition.get_details", "读取一项公开赛事的报名、认定和限制条件。", eventIDSchema(), mcp.getCompetitionDetails},
		campusMCPTool{"competition.compare", "比较两到四项公开赛事的报名期限、认定和参与条件。", compareSchema(), mcp.compareCompetitions},
		campusMCPTool{"competition.get_my_plan", "读取当前用户自己的竞赛计划，不返回其他用户数据。", limitSchema(), mcp.getMyCompetitionPlan},
		campusMCPTool{"competition.get_deadlines", "读取当前用户竞赛计划中即将到来的报名截止时间。", deadlineSchema(), mcp.getCompetitionDeadlines},
		campusMCPTool{"competition.get_calendar", "读取当前用户竞赛计划日历事件。", limitSchema(), mcp.getMyCompetitionPlan},
		campusMCPTool{"exam.search_materials", "检索已发布试卷资料的安全元数据，不返回文件内部存储地址。", searchSchema(), mcp.searchExamMaterials},
		campusMCPTool{"community.search_public_posts", "检索公开校园讨论，不返回联系方式或作者私有资料。", searchSchema(), mcp.searchPublicPosts},
		campusMCPTool{"academic.resolve_context", "解析已授权的服务端学业快照，返回来源、更新时间和过期状态。", resolveContextSchema(), mcp.resolveAcademicContext},
		campusMCPTool{"academic.get_grade_summary", "汇总已授权成绩快照中的课程数、学分和绩点。", emptySchema(), mcp.getGradeSummary},
		campusMCPTool{"academic.get_credit_summary", "返回已授权学分要求或学业情况快照中的摘要。", emptySchema(), mcp.getCreditSummary},
		campusMCPTool{"academic.get_failure_risk", "根据已授权成绩快照计算确定性的挂科风险计数。", emptySchema(), mcp.getFailureRisk},
		campusMCPTool{"academic.get_risk_analysis", "基于已授权成绩、学分和二课快照生成有边界的确定性风险与行动项。", emptySchema(), mcp.getRiskAnalysis},
		campusMCPTool{"schedule.get_availability", "根据已授权课表快照计算指定教学周的空闲节次。", availabilitySchema(), mcp.getScheduleAvailability},
		campusMCPTool{"erke.get_overview", "读取用户已授权上传的二课概览；没有上传时明确说明缺失。", emptySchema(), mcp.getErkeOverview},
		campusMCPTool{"profile.get_academic_identity", "读取当前用户已授权的年级、学院和专业，不返回学号或账号信息。", emptySchema(), mcp.getAcademicIdentity},
		campusMCPTool{"personal_calendar.get_events", "读取当前用户自己的个人日历事件。", calendarRangeSchema(), mcp.getPersonalCalendarRange},
		campusMCPTool{"personal_calendar.get_range", "读取当前用户日期范围内的个人日历事件。", calendarRangeSchema(), mcp.getPersonalCalendarRange},
		campusMCPTool{"personal_calendar.get_day", "读取当前用户指定日期的个人日历事件。", calendarDaySchema(), mcp.getPersonalCalendarDay},
		campusMCPTool{"personal_calendar.find_free_time", "根据个人日历事件计算可用时间窗口，不写入任何数据。", freeTimeSchema(), mcp.findPersonalFreeTime},
	}
}

func emptySchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{}, "additionalProperties": false}
}

func searchSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"query": map[string]interface{}{"type": "string", "minLength": 1, "maxLength": 120},
			"limit": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 10},
		}, "required": []string{"query"}, "additionalProperties": false,
	}
}

func termSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"academic_year": map[string]interface{}{"type": "string", "pattern": "^[0-9]{4}-[0-9]{4}$"},
		}, "additionalProperties": false,
	}
}

func calendarDaySchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"date": map[string]interface{}{"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
		}, "required": []string{"date"}, "additionalProperties": false,
	}
}

func calendarRangeSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"from": map[string]interface{}{"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
			"to":   map[string]interface{}{"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
		}, "required": []string{"from", "to"}, "additionalProperties": false,
	}
}

func dishSearchSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"query":      map[string]interface{}{"type": "string", "minLength": 1, "maxLength": 80},
		"canteen_id": map[string]interface{}{"type": "integer", "minimum": 1},
		"limit":      map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 20},
	}, "required": []string{"query"}, "additionalProperties": false}
}

func dishIDSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"dish_id": map[string]interface{}{"type": "integer", "minimum": 1},
	}, "required": []string{"dish_id"}, "additionalProperties": false}
}

func rankingSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"limit": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 20},
	}, "additionalProperties": false}
}

func recentReviewsSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"canteen_id": map[string]interface{}{"type": "integer", "minimum": 1},
		"limit":      map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 20},
	}, "required": []string{"canteen_id"}, "additionalProperties": false}
}

func limitSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"limit": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 50},
	}, "additionalProperties": false}
}

func deadlineSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"limit": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 20},
		"from":  map[string]interface{}{"type": "string", "format": "date-time"},
	}, "additionalProperties": false}
}

func freeTimeSchema() map[string]interface{} {
	return map[string]interface{}{"type": "object", "properties": map[string]interface{}{
		"from":             map[string]interface{}{"type": "string", "format": "date-time"},
		"to":               map[string]interface{}{"type": "string", "format": "date-time"},
		"duration_minutes": map[string]interface{}{"type": "integer", "minimum": 15, "maximum": 720},
	}, "required": []string{"from", "to", "duration_minutes"}, "additionalProperties": false}
}

func canteenSearchSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"query": map[string]interface{}{"type": "string", "minLength": 1, "maxLength": 80},
			"limit": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 10},
		}, "required": []string{"query"}, "additionalProperties": false,
	}
}

func canteenIDSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"canteen_id": map[string]interface{}{"type": "integer", "minimum": 1},
		}, "required": []string{"canteen_id"}, "additionalProperties": false,
	}
}

func competitionSearchSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"query": map[string]interface{}{"type": "string", "maxLength": 120},
			"limit": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 10},
		}, "additionalProperties": false,
	}
}

func eventIDSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"event_id": map[string]interface{}{"type": "integer", "minimum": 1},
		}, "required": []string{"event_id"}, "additionalProperties": false,
	}
}

func compareSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"event_ids": map[string]interface{}{"type": "array", "minItems": 2, "maxItems": 4, "items": map[string]interface{}{"type": "integer", "minimum": 1}},
		}, "required": []string{"event_ids"}, "additionalProperties": false,
	}
}

func resolveContextSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"datasets":                 map[string]interface{}{"type": "array", "minItems": 1, "maxItems": 6, "items": map[string]interface{}{"type": "string", "enum": []string{"grades", "schedule", "academic_situation", "credit_requirements", "credit_summary", "erke"}}},
			"freshness":                map[string]interface{}{"type": "string", "enum": []string{"prefer_recent", "require_fresh", "allow_stale"}},
			"reason":                   map[string]interface{}{"type": "string", "maxLength": 120},
			"schedule_week_containing": map[string]interface{}{"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
		}, "required": []string{"datasets", "freshness", "reason"}, "additionalProperties": false,
	}
}

func availabilitySchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"week":                     map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 30},
			"weekdays":                 map[string]interface{}{"type": "array", "minItems": 1, "maxItems": 7, "items": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 7}},
			"schedule_week_containing": map[string]interface{}{"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
		}, "required": []string{"week", "schedule_week_containing"}, "additionalProperties": false,
	}
}

type searchArguments struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
}

func decodeToolArguments(arguments json.RawMessage, target interface{}) error {
	decoder := json.NewDecoder(bytes.NewReader(arguments))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return errors.New("invalid_tool_arguments")
	}
	if decoder.More() {
		return errors.New("invalid_tool_arguments")
	}
	return nil
}

func normalizeSearchArguments(arguments json.RawMessage) (searchArguments, error) {
	var input searchArguments
	if err := decodeToolArguments(arguments, &input); err != nil {
		return searchArguments{}, err
	}
	input.Query = strings.TrimSpace(input.Query)
	if input.Query == "" || len([]rune(input.Query)) > 120 {
		return searchArguments{}, errors.New("invalid_tool_arguments")
	}
	if input.Limit == 0 {
		input.Limit = 5
	}
	if input.Limit < 1 || input.Limit > 10 {
		return searchArguments{}, errors.New("invalid_tool_arguments")
	}
	return input, nil
}

func (mcp *campusMCP) searchPolicy(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	input, err := normalizeSearchArguments(arguments)
	if err != nil {
		return nil, err
	}
	var items []knowledgeItem
	if mcp.policyRetriever == nil {
		items, err = mcp.searchKnowledge(ctx, input.Query, input.Limit, nil)
	} else {
		var retrieval RetrievalResult
		retrieval, err = mcp.policyRetriever.Retrieve(ctx, input.Query)
		if err == nil {
			items = knowledgeItemsFromChunks(retrieval.Chunks, input.Limit)
		}
	}
	if err != nil {
		return nil, err
	}
	return publicResult(items, academic.DataSourceKnowledgeBase, knowledgeEvidence(items), mcp.now()), nil
}

func knowledgeItemsFromChunks(chunks []RetrievedChunk, limit int) []knowledgeItem {
	if limit <= 0 || limit > len(chunks) {
		limit = len(chunks)
	}
	items := make([]knowledgeItem, 0, limit)
	for _, chunk := range chunks[:limit] {
		items = append(items, knowledgeItem{Title: chunk.Title, Department: chunk.Department,
			DocumentType: chunk.DocumentType, SectionTitle: chunk.SectionTitle,
			Excerpt: truncateToolText(chunk.Content, 800), SourceURL: chunk.SourceURI, PublishedAt: chunk.PublishedAt})
	}
	return items
}

func (mcp *campusMCP) searchService(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	input, err := normalizeSearchArguments(arguments)
	if err != nil {
		return nil, err
	}
	items, err := mcp.searchKnowledge(ctx, input.Query, input.Limit, []string{"service", "campus_service"})
	if err != nil {
		return nil, err
	}
	return publicResult(items, academic.DataSourceKnowledgeBase, knowledgeEvidence(items), mcp.now()), nil
}

type knowledgeItem struct {
	Title        string     `json:"title"`
	Department   string     `json:"department,omitempty"`
	DocumentType string     `json:"document_type,omitempty"`
	SectionTitle string     `json:"section_title,omitempty"`
	Excerpt      string     `json:"excerpt"`
	SourceURL    string     `json:"source_url,omitempty"`
	PublishedAt  *time.Time `json:"published_at,omitempty"`
}

func (mcp *campusMCP) searchKnowledge(ctx context.Context, query string, limit int, documentTypes []string) ([]knowledgeItem, error) {
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	db := mcp.db.WithContext(ctx).Model(&models.AIKnowledgeDocument{}).
		Where("status = ?", models.KnowledgeStatusPublished)
	terms := knowledgeSearchTerms(query)
	predicates := make([]string, 0, len(terms))
	values := make([]interface{}, 0, len(terms)*2)
	for _, term := range terms {
		predicates = append(predicates, "(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)")
		pattern := "%" + term + "%"
		values = append(values, pattern, pattern)
	}
	db = db.Where(strings.Join(predicates, " OR "), values...)
	if len(documentTypes) > 0 {
		db = db.Where("document_type IN ?", documentTypes)
	}
	var documents []models.AIKnowledgeDocument
	if err := db.Order("published_at DESC, id DESC").Limit(limit).Find(&documents).Error; err != nil {
		return nil, err
	}
	items := make([]knowledgeItem, 0, len(documents))
	for _, document := range documents {
		items = append(items, knowledgeItem{Title: document.Title, Department: document.Department, DocumentType: document.DocumentType, Excerpt: truncateToolText(document.Content, 800), SourceURL: document.SourceURI, PublishedAt: document.PublishedAt})
	}
	return items, nil
}

func knowledgeSearchTerms(query string) []string {
	fields := strings.Fields(strings.ToLower(strings.TrimSpace(query)))
	terms := make([]string, 0, len(fields))
	seen := make(map[string]struct{}, len(fields))
	for _, field := range fields {
		term := strings.Trim(field, "，。！？；：、,.!?;:()（）[]【】")
		if term == "" {
			continue
		}
		if _, exists := seen[term]; exists {
			continue
		}
		seen[term] = struct{}{}
		terms = append(terms, term)
		if len(terms) == 8 {
			break
		}
	}
	if len(terms) == 0 {
		return []string{strings.ToLower(strings.TrimSpace(query))}
	}
	return terms
}

func knowledgeEvidence(items []knowledgeItem) []CampusToolEvidence {
	result := make([]CampusToolEvidence, 0, len(items))
	for _, item := range items {
		result = append(result, CampusToolEvidence{Source: academic.DataSourceKnowledgeBase, Title: item.Title, URL: item.SourceURL, FetchedAt: item.PublishedAt})
	}
	return result
}

func (mcp *campusMCP) searchNotifications(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	input, err := normalizeSearchArguments(arguments)
	if err != nil {
		return nil, err
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	pattern := "%" + strings.ToLower(input.Query) + "%"
	var articles []models.CampusArticle
	if err := mcp.db.WithContext(ctx).Where("source IN ? AND (LOWER(title) LIKE ? OR LOWER(content_text) LIKE ?)", []string{"jwc", "cxcy"}, pattern, pattern).Order("publish_date DESC, id DESC").Limit(input.Limit).Find(&articles).Error; err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(articles))
	evidence := make([]CampusToolEvidence, 0, len(articles))
	for _, article := range articles {
		publishedAt := article.PublishDate
		items = append(items, map[string]interface{}{"title": article.Title, "category": article.Category, "publish_date": article.PublishDate.Format("2006-01-02"), "department": article.AuthorDepartment, "excerpt": truncateToolText(article.ContentText, 800), "source_url": article.SourceURL})
		evidence = append(evidence, CampusToolEvidence{Source: academic.DataSourcePublicDatabase, Title: article.Title, URL: article.SourceURL, FetchedAt: &publishedAt})
	}
	return publicResult(items, academic.DataSourcePublicDatabase, evidence, mcp.now()), nil
}

func (mcp *campusMCP) getTermInfo(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		AcademicYear string `json:"academic_year"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil {
		return nil, err
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	db := mcp.db.WithContext(ctx).Where("status = ?", "published")
	if input.AcademicYear = strings.TrimSpace(input.AcademicYear); input.AcademicYear != "" {
		if !academicYearInputValid(input.AcademicYear) {
			return nil, errors.New("invalid_tool_arguments")
		}
		db = db.Where("academic_year = ?", input.AcademicYear)
	}
	var calendar models.CampusCalendar
	if err := db.Order("academic_year DESC, version DESC").First(&calendar).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return publicMissingResult("暂未发布可用校历"), nil
		}
		return nil, err
	}
	var data interface{}
	if err := json.Unmarshal(calendar.Data, &data); err != nil {
		return nil, errors.New("campus_calendar_corrupted")
	}
	publishedAt := calendar.UpdatedAt
	return publicResult(data, academic.DataSourcePublicDatabase, []CampusToolEvidence{{Source: academic.DataSourcePublicDatabase, Title: calendar.SourceName, FetchedAt: &publishedAt}}, publishedAt), nil
}

func (mcp *campusMCP) getCalendarDay(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Date string `json:"date"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || !calendarDateInputValid(input.Date) {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var calendar models.CampusCalendar
	if err := mcp.db.WithContext(ctx).Where("status = ?", "published").Order("academic_year DESC, version DESC").First(&calendar).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return publicMissingResult("暂未发布可用校历"), nil
		}
		return nil, err
	}
	var root map[string]interface{}
	if err := json.Unmarshal(calendar.Data, &root); err != nil {
		return nil, errors.New("campus_calendar_corrupted")
	}
	date, _ := time.Parse("2006-01-02", input.Date)
	var semester map[string]interface{}
	var teachingWeek map[string]interface{}
	for _, raw := range calendarObjectList(root["semesters"]) {
		start, startOK := calendarDateValue(raw["start_date"])
		end, endOK := calendarDateValue(raw["end_date"])
		if !startOK || !endOK || date.Before(start) || date.After(end) {
			continue
		}
		semester = raw
		for _, week := range calendarObjectList(raw["teaching_weeks"]) {
			weekStart, weekStartOK := calendarDateValue(week["start_date"])
			weekEnd, weekEndOK := calendarDateValue(week["end_date"])
			if weekStartOK && weekEndOK && !date.Before(weekStart) && !date.After(weekEnd) {
				teachingWeek = week
				break
			}
		}
		break
	}
	var override map[string]interface{}
	for _, raw := range calendarObjectList(root["day_overrides"]) {
		if value, ok := raw["date"].(string); ok && value == input.Date {
			override = raw
			break
		}
	}
	events := make([]map[string]interface{}, 0)
	for _, raw := range calendarObjectList(root["events"]) {
		start, startOK := calendarDateValue(raw["start_date"])
		end, endOK := calendarDateValue(raw["end_date"])
		if startOK && endOK && !date.Before(start) && !date.After(end) {
			events = append(events, raw)
		}
	}
	publishedAt := calendar.UpdatedAt
	return publicResult(map[string]interface{}{
		"date": input.Date, "academic_year": calendar.AcademicYear,
		"semester": semester, "teaching_week": teachingWeek, "override": override, "events": events,
	}, academic.DataSourcePublicDatabase, []CampusToolEvidence{{Source: academic.DataSourcePublicDatabase, Title: calendar.SourceName, FetchedAt: &publishedAt}}, publishedAt), nil
}

func (mcp *campusMCP) getCalendarRange(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct{ From, To string }
	if err := decodeToolArguments(arguments, &input); err != nil || !calendarDateInputValid(input.From) || !calendarDateInputValid(input.To) {
		return nil, errors.New("invalid_tool_arguments")
	}
	from, _ := time.Parse("2006-01-02", input.From)
	to, _ := time.Parse("2006-01-02", input.To)
	if to.Before(from) || to.Sub(from) > 31*24*time.Hour {
		return nil, errors.New("invalid_tool_arguments")
	}
	days := make([]interface{}, 0, int(to.Sub(from)/24/time.Hour)+1)
	for day := from; !day.After(to); day = day.AddDate(0, 0, 1) {
		value, err := mcp.getCalendarDay(ctx, 0, mustMarshal(map[string]string{"date": day.Format("2006-01-02")}))
		if err != nil {
			return nil, err
		}
		result, ok := value.(CampusToolResult)
		if !ok {
			return nil, errors.New("calendar_result_invalid")
		}
		days = append(days, result.Data)
	}
	return publicResult(map[string]interface{}{"from": input.From, "to": input.To, "days": days}, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

func (mcp *campusMCP) getCurrentTerm(ctx context.Context, _ uint, _ json.RawMessage) (interface{}, error) {
	return mcp.getTermInfo(ctx, 0, json.RawMessage(`{}`))
}

func (mcp *campusMCP) getTeachingWeek(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	value, err := mcp.getCalendarDay(ctx, 0, arguments)
	if err != nil {
		return nil, err
	}
	result, ok := value.(CampusToolResult)
	if !ok {
		return nil, errors.New("calendar_result_invalid")
	}
	data, ok := result.Data.(map[string]interface{})
	if !ok {
		return value, nil
	}
	return publicResult(map[string]interface{}{
		"date": data["date"], "academic_year": data["academic_year"],
		"semester": data["semester"], "teaching_week": data["teaching_week"], "override": data["override"],
	}, result.Source, result.Evidence, mcp.now()), nil
}

func calendarDateInputValid(value string) bool {
	if len(value) != len("2006-01-02") {
		return false
	}
	parsed, err := time.Parse("2006-01-02", value)
	return err == nil && parsed.Format("2006-01-02") == value
}

func calendarDateValue(value interface{}) (time.Time, bool) {
	text, ok := value.(string)
	if !ok {
		return time.Time{}, false
	}
	parsed, err := time.Parse("2006-01-02", text)
	return parsed, err == nil
}

func calendarObjectList(value interface{}) []map[string]interface{} {
	items, ok := value.([]interface{})
	if !ok {
		return nil
	}
	result := make([]map[string]interface{}, 0, len(items))
	for _, item := range items {
		if object, ok := item.(map[string]interface{}); ok {
			result = append(result, object)
		}
	}
	return result
}

func (mcp *campusMCP) searchCanteens(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || strings.TrimSpace(input.Query) == "" || len([]rune(input.Query)) > 80 || input.Limit < 0 || input.Limit > 10 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if input.Limit == 0 {
		input.Limit = 5
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	pattern := "%" + strings.ToLower(strings.TrimSpace(input.Query)) + "%"
	var canteens []models.Canteen
	if err := mcp.db.WithContext(ctx).Where("verified = ? AND (operating_status = ? OR operating_status IS NULL OR operating_status = '') AND (LOWER(name) LIKE ? OR LOWER(normalized_name) LIKE ?)", true, models.CanteenOperatingActive, pattern, pattern).Order("name ASC, id ASC").Limit(input.Limit).Find(&canteens).Error; err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(canteens))
	for _, canteen := range canteens {
		items = append(items, map[string]interface{}{"id": canteen.ID, "name": canteen.Name, "image": canteen.Image, "verified": canteen.Verified, "operating_status": canteen.OperatingStatus})
	}
	return publicResult(items, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

func (mcp *campusMCP) getCanteenDetails(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		CanteenID uint `json:"canteen_id"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.CanteenID == 0 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var canteen models.Canteen
	if err := mcp.db.WithContext(ctx).Where("id = ? AND verified = ? AND (operating_status = ? OR operating_status IS NULL OR operating_status = '')", input.CanteenID, true, models.CanteenOperatingActive).First(&canteen).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return publicMissingResult("食堂不存在或当前不可用"), nil
		}
		return nil, err
	}
	var dishes []models.CanteenDish
	if err := mcp.db.WithContext(ctx).Where("canteen_id = ? AND status = ?", canteen.ID, models.DishStatusActive).Order("name ASC, id ASC").Limit(100).Find(&dishes).Error; err != nil {
		return nil, err
	}
	publicDishes := make([]map[string]interface{}, 0, len(dishes))
	for _, dish := range dishes {
		publicDishes = append(publicDishes, map[string]interface{}{"id": dish.ID, "name": dish.Name, "status": dish.Status})
	}
	data := map[string]interface{}{"id": canteen.ID, "name": canteen.Name, "image": canteen.Image, "operating_status": canteen.OperatingStatus, "dishes": publicDishes}
	return publicResult(data, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

func (mcp *campusMCP) searchDishes(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Query     string `json:"query"`
		CanteenID uint   `json:"canteen_id"`
		Limit     int    `json:"limit"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || strings.TrimSpace(input.Query) == "" || len([]rune(input.Query)) > 80 || input.Limit < 0 || input.Limit > 20 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	if input.Limit == 0 {
		input.Limit = 10
	}
	pattern := "%" + strings.ToLower(strings.TrimSpace(input.Query)) + "%"
	query := mcp.db.WithContext(ctx).Table("canteen_dishes AS d").
		Select("d.*").Joins("JOIN canteens c ON c.id = d.canteen_id").
		Where("d.status = ? AND c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '') AND (LOWER(d.name) LIKE ? OR LOWER(d.normalized_name) LIKE ?)", models.DishStatusActive, true, models.CanteenOperatingActive, pattern, pattern)
	if input.CanteenID != 0 {
		query = query.Where("d.canteen_id = ?", input.CanteenID)
	}
	var dishes []models.CanteenDish
	if err := query.Order("d.name ASC, d.id ASC").Limit(input.Limit).Find(&dishes).Error; err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(dishes))
	for _, dish := range dishes {
		items = append(items, map[string]interface{}{"dish_id": dish.ID, "canteen_id": dish.CanteenID, "name": dish.Name, "status": dish.Status})
	}
	return publicResult(items, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

func (mcp *campusMCP) getDishDetails(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		DishID uint `json:"dish_id"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.DishID == 0 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var dish models.CanteenDish
	if err := mcp.db.WithContext(ctx).Table("canteen_dishes AS d").Select("d.*").Joins("JOIN canteens c ON c.id = d.canteen_id").Where("d.id = ? AND d.status = ? AND c.verified = ? AND (c.operating_status = ? OR c.operating_status IS NULL OR c.operating_status = '')", input.DishID, models.DishStatusActive, true, models.CanteenOperatingActive).First(&dish).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return publicMissingResult("菜品不存在或当前不可用"), nil
		}
		return nil, err
	}
	var summaries []models.CanteenDishRatingSummary
	if err := mcp.db.WithContext(ctx).Where("dish_id = ?", dish.ID).Find(&summaries).Error; err != nil {
		return nil, err
	}
	var total float64
	for _, summary := range summaries {
		total += summary.EffectiveScore
	}
	data := map[string]interface{}{"dish_id": dish.ID, "canteen_id": dish.CanteenID, "name": dish.Name, "status": dish.Status, "rating_count": len(summaries), "average_score": 0.0}
	if len(summaries) > 0 {
		data["average_score"] = roundToolNumber(total / float64(len(summaries)))
	}
	return publicResult(data, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

func (mcp *campusMCP) getCanteenRankings(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Limit int `json:"limit"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.Limit < 0 || input.Limit > 20 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	if input.Limit == 0 {
		input.Limit = 10
	}
	var canteens []models.Canteen
	if err := mcp.db.WithContext(ctx).Where("verified = ? AND (operating_status = ? OR operating_status IS NULL OR operating_status = '')", true, models.CanteenOperatingActive).Find(&canteens).Error; err != nil {
		return nil, err
	}
	var ratings []models.CanteenRating
	if err := mcp.db.WithContext(ctx).Where("status = ?", models.ReviewEventStatusActive).Find(&ratings).Error; err != nil {
		return nil, err
	}
	totals := map[uint]struct {
		sum   float64
		count int
	}{}
	for _, rating := range ratings {
		current := totals[rating.CanteenID]
		score := rating.EffectiveScore
		if score == 0 {
			score = float64(rating.Star)
		}
		current.sum += score
		current.count++
		totals[rating.CanteenID] = current
	}
	type ranked struct {
		item  map[string]interface{}
		score float64
	}
	items := make([]ranked, 0, len(canteens))
	for _, canteen := range canteens {
		current := totals[canteen.ID]
		if current.count == 0 {
			continue
		}
		items = append(items, ranked{map[string]interface{}{"canteen_id": canteen.ID, "name": canteen.Name, "average_score": roundToolNumber(current.sum / float64(current.count)), "rating_count": current.count}, current.sum / float64(current.count)})
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].score == items[j].score {
			return fmt.Sprint(items[i].item["name"]) < fmt.Sprint(items[j].item["name"])
		}
		return items[i].score > items[j].score
	})
	data := make([]map[string]interface{}, 0, minInt(input.Limit, len(items)))
	for _, item := range items[:minInt(input.Limit, len(items))] {
		data = append(data, item.item)
	}
	return publicResult(data, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

func (mcp *campusMCP) getRecentCanteenReviews(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		CanteenID uint `json:"canteen_id"`
		Limit     int  `json:"limit"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.CanteenID == 0 || input.Limit < 0 || input.Limit > 20 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	if input.Limit == 0 {
		input.Limit = 10
	}
	var canteen models.Canteen
	if err := mcp.db.WithContext(ctx).Where("id = ? AND verified = ? AND (operating_status = ? OR operating_status IS NULL OR operating_status = '')", input.CanteenID, true, models.CanteenOperatingActive).First(&canteen).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return publicMissingResult("食堂不存在或当前不可用"), nil
		}
		return nil, err
	}
	var reviews []models.CanteenReviewEvent
	if err := mcp.db.WithContext(ctx).Where("canteen_id = ? AND status = ?", canteen.ID, models.ReviewEventStatusActive).Order("created_at DESC, id DESC").Limit(input.Limit).Find(&reviews).Error; err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(reviews))
	for _, review := range reviews {
		items = append(items, map[string]interface{}{"review_id": review.ID, "overall_score": review.OverallScore, "taste_score": review.TasteScore, "value_score": review.ValueScore, "queue_score": review.QueueScore, "hygiene_score": review.HygieneScore, "service_score": review.ServiceScore, "comment": truncateToolText(review.Comment, 240), "created_at": review.CreatedAt})
	}
	return publicResult(items, academic.DataSourcePublicDatabase, nil, mcp.now()), nil
}

type competitionSearchArguments struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
}

func (mcp *campusMCP) searchCompetitionCatalog(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input competitionSearchArguments
	if err := decodeToolArguments(arguments, &input); err != nil {
		return nil, err
	}
	if len([]rune(input.Query)) > 120 || input.Limit < 0 || input.Limit > 10 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if input.Limit == 0 {
		input.Limit = 5
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	db := mcp.db.WithContext(ctx).Preload("PrimaryCategory").Where("status IN ?", []string{"active", "published"})
	if query := strings.TrimSpace(input.Query); query != "" {
		pattern := "%" + strings.ToLower(query) + "%"
		db = db.Where("LOWER(title) LIKE ? OR LOWER(summary) LIKE ?", pattern, pattern)
	}
	var events []models.CompetitionEvent
	if err := db.Order("registration_end ASC, importance_score DESC, id DESC").Limit(input.Limit).Find(&events).Error; err != nil {
		return nil, err
	}
	return publicResult(competitionSummaries(events), academic.DataSourcePublicDatabase, competitionEvidence(events), mcp.now()), nil
}

func (mcp *campusMCP) getCompetitionDetails(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		EventID uint `json:"event_id"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.EventID == 0 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var event models.CompetitionEvent
	if err := mcp.db.WithContext(ctx).Preload("PrimaryCategory").Where("id = ? AND status IN ?", input.EventID, []string{"active", "published"}).First(&event).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return publicMissingResult("赛事不存在或未公开"), nil
		}
		return nil, err
	}
	return publicResult(competitionDetail(event), academic.DataSourcePublicDatabase, competitionEvidence([]models.CompetitionEvent{event}), event.UpdatedAt), nil
}

func (mcp *campusMCP) compareCompetitions(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		EventIDs []uint `json:"event_ids"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || len(input.EventIDs) < 2 || len(input.EventIDs) > 4 {
		return nil, errors.New("invalid_tool_arguments")
	}
	seen := make(map[uint]struct{}, len(input.EventIDs))
	for _, id := range input.EventIDs {
		if id == 0 {
			return nil, errors.New("invalid_tool_arguments")
		}
		if _, ok := seen[id]; ok {
			return nil, errors.New("invalid_tool_arguments")
		}
		seen[id] = struct{}{}
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var events []models.CompetitionEvent
	if err := mcp.db.WithContext(ctx).Preload("PrimaryCategory").Where("id IN ? AND status IN ?", input.EventIDs, []string{"active", "published"}).Find(&events).Error; err != nil {
		return nil, err
	}
	byID := make(map[uint]models.CompetitionEvent, len(events))
	for _, event := range events {
		byID[event.ID] = event
	}
	items := make([]interface{}, 0, len(input.EventIDs))
	evidence := make([]CampusToolEvidence, 0, len(input.EventIDs))
	for _, id := range input.EventIDs {
		if event, ok := byID[id]; ok {
			items = append(items, competitionDetail(event))
			evidence = append(evidence, competitionEvidence([]models.CompetitionEvent{event})...)
		}
	}
	result := publicResult(items, academic.DataSourcePublicDatabase, evidence, mcp.now())
	if len(items) != len(input.EventIDs) {
		result.IsPartial = true
		result.Status = academic.DataStatusPartial
		result.Warnings = append(result.Warnings, "部分赛事不存在或未公开")
	}
	return result, nil
}

func (mcp *campusMCP) getMyCompetitionPlan(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	limit, err := toolLimit(arguments, 50)
	if err != nil || userID == 0 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var items []models.UserCompetitionCalendarItem
	if err := mcp.db.WithContext(ctx).Where("user_id = ?", userID).Order("sort_date ASC, is_pinned DESC, id ASC").Limit(limit).Find(&items).Error; err != nil {
		return nil, err
	}
	data := make([]map[string]interface{}, 0, len(items))
	for _, item := range items {
		data = append(data, map[string]interface{}{"id": item.ID, "title": item.Title, "summary": item.Summary, "plan_status": item.PlanStatus, "registration_end": item.RegistrationEnd, "event_start": item.EventStart, "event_end": item.EventEnd, "user_deadline": item.UserDeadline, "official_url": item.OfficialURL, "source_type": item.SourceType})
	}
	return publicResult(data, academic.DataSourceServerSnapshot, nil, mcp.now()), nil
}

func (mcp *campusMCP) getCompetitionDeadlines(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Limit int    `json:"limit"`
		From  string `json:"from"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || userID == 0 || input.Limit < 0 || input.Limit > 20 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	if input.Limit == 0 {
		input.Limit = 10
	}
	from := mcp.now()
	if strings.TrimSpace(input.From) != "" {
		parsed, err := time.Parse(time.RFC3339, input.From)
		if err != nil {
			return nil, errors.New("invalid_tool_arguments")
		}
		from = parsed
	}
	var items []models.UserCompetitionCalendarItem
	if err := mcp.db.WithContext(ctx).Where("user_id = ? AND registration_end IS NOT NULL AND registration_end >= ?", userID, from).Order("registration_end ASC, id ASC").Limit(input.Limit).Find(&items).Error; err != nil {
		return nil, err
	}
	data := make([]map[string]interface{}, 0, len(items))
	for _, item := range items {
		data = append(data, map[string]interface{}{"id": item.ID, "title": item.Title, "registration_end": item.RegistrationEnd, "registration_end_text": item.RegistrationEndText, "official_url": item.OfficialURL, "plan_status": item.PlanStatus})
	}
	return publicResult(data, academic.DataSourceServerSnapshot, nil, mcp.now()), nil
}

func (mcp *campusMCP) getPersonalCalendarRange(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if userID == 0 || mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var input struct{ From, To string }
	if err := decodeToolArguments(arguments, &input); err != nil || !calendarDateInputValid(input.From) || !calendarDateInputValid(input.To) {
		return nil, errors.New("invalid_tool_arguments")
	}
	from, _ := time.ParseInLocation("2006-01-02", input.From, time.FixedZone("Asia/Shanghai", 8*60*60))
	toDate, _ := time.ParseInLocation("2006-01-02", input.To, time.FixedZone("Asia/Shanghai", 8*60*60))
	to := toDate.AddDate(0, 0, 1)
	if to.Before(from) || to.Sub(from) > 31*24*time.Hour {
		return nil, errors.New("invalid_tool_arguments")
	}
	var events []models.UserCalendarEvent
	if err := mcp.db.WithContext(ctx).Where("user_id = ? AND start_at < ? AND end_at > ?", userID, to.UTC(), from.UTC()).Order("start_at ASC, id ASC").Find(&events).Error; err != nil {
		return nil, err
	}
	data := make([]map[string]interface{}, 0, len(events))
	for _, event := range events {
		data = append(data, map[string]interface{}{"id": event.ID, "title": event.Title, "description": event.Description, "start_at": event.StartAt, "end_at": event.EndAt, "all_day": event.AllDay, "location": event.Location, "timezone": event.Timezone, "source_type": event.SourceType})
	}
	return publicResult(map[string]interface{}{"from": input.From, "to": input.To, "events": data}, academic.DataSourceServerSnapshot, nil, mcp.now()), nil
}

func (mcp *campusMCP) getPersonalCalendarDay(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Date string `json:"date"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || !calendarDateInputValid(input.Date) {
		return nil, errors.New("invalid_tool_arguments")
	}
	return mcp.getPersonalCalendarRange(ctx, userID, mustMarshal(map[string]string{"from": input.Date, "to": input.Date}))
}

func (mcp *campusMCP) findPersonalFreeTime(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		From            string `json:"from"`
		To              string `json:"to"`
		DurationMinutes int    `json:"duration_minutes"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || userID == 0 || input.DurationMinutes < 15 || input.DurationMinutes > 720 {
		return nil, errors.New("invalid_tool_arguments")
	}
	from, err := time.Parse(time.RFC3339, input.From)
	if err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	to, err := time.Parse(time.RFC3339, input.To)
	if err != nil || !to.After(from) || to.Sub(from) > 14*24*time.Hour {
		return nil, errors.New("invalid_tool_arguments")
	}
	var events []models.UserCalendarEvent
	if err := mcp.db.WithContext(ctx).Where("user_id = ? AND start_at < ? AND end_at > ?", userID, to, from).Order("start_at ASC").Find(&events).Error; err != nil {
		return nil, err
	}
	var competitionItems []models.UserCompetitionCalendarItem
	if err := mcp.db.WithContext(ctx).Where("user_id = ? AND event_start IS NOT NULL AND event_end IS NOT NULL AND event_start < ? AND event_end > ?", userID, to, from).Find(&competitionItems).Error; err != nil {
		return nil, err
	}
	type busyRange struct{ start, end time.Time }
	busy := make([]busyRange, 0, len(events)+len(competitionItems))
	for _, event := range events {
		busy = append(busy, busyRange{event.StartAt, event.EndAt})
	}
	for _, item := range competitionItems {
		busy = append(busy, busyRange{*item.EventStart, *item.EventEnd})
	}
	sort.Slice(busy, func(i, j int) bool { return busy[i].start.Before(busy[j].start) })
	busyEnd := from
	data := make([]map[string]interface{}, 0, 20)
	for _, event := range busy {
		if event.start.After(busyEnd) && event.start.Sub(busyEnd) >= time.Duration(input.DurationMinutes)*time.Minute {
			data = append(data, map[string]interface{}{"start": busyEnd, "end": event.start})
			if len(data) >= 20 {
				break
			}
		}
		if event.end.After(busyEnd) {
			busyEnd = event.end
		}
	}
	if len(data) < 20 && to.After(busyEnd) && to.Sub(busyEnd) >= time.Duration(input.DurationMinutes)*time.Minute {
		data = append(data, map[string]interface{}{"start": busyEnd, "end": to})
	}
	return publicResult(map[string]interface{}{"from": from, "to": to, "duration_minutes": input.DurationMinutes, "available_windows": data}, academic.DataSourceServerSnapshot, nil, mcp.now()), nil
}

func (mcp *campusMCP) searchExamMaterials(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	input, err := normalizeSearchArguments(arguments)
	if err != nil {
		return nil, err
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	pattern := "%" + strings.ToLower(input.Query) + "%"
	var papers []models.ExamPaper
	if err := mcp.db.WithContext(ctx).Where("status = ? AND (LOWER(course_name) LIKE ? OR LOWER(title) LIKE ?)", models.ExamPaperStatusPublished, pattern, pattern).Order("published_at DESC, id DESC").Limit(input.Limit).Find(&papers).Error; err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(papers))
	evidence := make([]CampusToolEvidence, 0, len(papers))
	for _, paper := range papers {
		items = append(items, map[string]interface{}{"title": paper.Title, "course_name": paper.CourseName, "academic_year": paper.AcademicYear, "semester": paper.Semester, "exam_type": paper.ExamType, "published_at": paper.PublishedAt})
		evidence = append(evidence, CampusToolEvidence{Source: academic.DataSourcePublicDatabase, Title: paper.Title, FetchedAt: paper.PublishedAt})
	}
	return publicResult(items, academic.DataSourcePublicDatabase, evidence, mcp.now()), nil
}

func (mcp *campusMCP) searchPublicPosts(ctx context.Context, _ uint, arguments json.RawMessage) (interface{}, error) {
	input, err := normalizeSearchArguments(arguments)
	if err != nil {
		return nil, err
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	pattern := "%" + strings.ToLower(input.Query) + "%"
	var posts []models.Post
	if err := mcp.db.WithContext(ctx).Where("board_id = ? AND status = ? AND (LOWER(title) LIKE ? OR LOWER(content) LIKE ?)", models.BoardShuitie, models.PostStatusNormal, pattern, pattern).Order("last_activity_at DESC, id DESC").Limit(input.Limit).Find(&posts).Error; err != nil {
		return nil, err
	}
	items := make([]map[string]interface{}, 0, len(posts))
	evidence := make([]CampusToolEvidence, 0, len(posts))
	for _, post := range posts {
		createdAt := post.CreatedAt
		title := strings.TrimSpace(post.Title)
		if title == "" {
			title = "校园公开讨论"
		}
		items = append(items, map[string]interface{}{"title": title, "content": truncateToolText(post.Content, 600), "post_type": post.PostType, "created_at": createdAt, "reply_count": post.ReplyCount})
		evidence = append(evidence, CampusToolEvidence{Source: academic.DataSourcePublicDatabase, Title: title, FetchedAt: &createdAt})
	}
	return publicResult(items, academic.DataSourcePublicDatabase, evidence, mcp.now()), nil
}

func (mcp *campusMCP) resolveAcademicContext(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var request academic.ResolveContextRequest
	if err := decodeToolArguments(arguments, &request); err != nil {
		return nil, err
	}
	if err := request.Validate(); err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	results, wait, err := mcp.resolveSnapshots(ctx, userID, request)
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	data := make(map[string]academic.ContextResult, len(results))
	evidence := make([]CampusToolEvidence, 0, len(results))
	status := academic.DataStatusAvailable
	source := academic.DataSourceServerSnapshot
	partial := false
	for dataset, result := range results {
		data[string(dataset)] = result
		if result.Status != academic.DataStatusAvailable {
			partial = true
			status = academic.DataStatusPartial
		}
		for _, item := range result.Evidence {
			evidence = append(evidence, CampusToolEvidence{Source: item.Source, Dataset: item.Dataset, FetchedAt: item.FetchedAt, ExpiresAt: item.ExpiresAt, IsStale: item.IsStale})
		}
	}
	if len(evidence) == 0 {
		source = academic.DataSourceNone
		if status == academic.DataStatusAvailable {
			status = academic.DataStatusMissing
		}
	}
	return CampusToolResult{Data: data, Status: status, Source: source, IsPartial: partial, Warnings: make([]string, 0), Evidence: evidence}, nil
}

// waitForPersonalContext 仅处理服务端快照未命中后的设备缓存权限与任务调度。
func (mcp *campusMCP) waitForPersonalContext(ctx context.Context, userID uint, request academic.ResolveContextRequest, results map[academic.DatasetType]academic.ContextResult) *ToolWait {
	call, hasCall := currentToolCallContext(ctx)
	if !hasCall {
		return nil
	}
	if mcp.deviceJobs == nil {
		return nil
	}
	needsDevice := false
	for _, dataset := range request.Datasets {
		result := results[dataset]
		if result.Status == academic.DataStatusMissing || result.Status == academic.DataStatusNeedsRefresh {
			needsDevice = true
			break
		}
	}
	if !needsDevice {
		return nil
	}
	wait, denied, err := mcp.requirePermission(ctx, userID, models.AIUserPermissionDeviceCacheAccess, request.Reason)
	if err != nil {
		for _, dataset := range request.Datasets {
			result := results[dataset]
			if result.Status == academic.DataStatusMissing || result.Status == academic.DataStatusNeedsRefresh {
				results[dataset] = personalContextUnavailable(academic.DataStatusFailed, "权限服务暂时不可用，请稍后重试")
			}
		}
		return nil
	}
	if denied {
		for _, dataset := range request.Datasets {
			result := results[dataset]
			if result.Status == academic.DataStatusMissing || result.Status == academic.DataStatusNeedsRefresh {
				results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 读取手机本地缓存")
			}
		}
		return nil
	}
	if wait != nil {
		return wait
	}
	// 强制新鲜度不仅需要读取设备缓存，还可能触发教务刷新。
	// 两个权限必须在创建设备任务前分别通过，避免把“读取缓存”权限
	// 意外扩大成“联网刷新教务”权限。
	if request.Freshness == academic.FreshnessRequireFresh {
		refreshWait, refreshDenied, refreshErr := mcp.requirePermission(
			ctx,
			userID,
			models.AIUserPermissionRemoteEduRefresh,
			request.Reason,
		)
		if refreshErr != nil {
			for _, dataset := range request.Datasets {
				result := results[dataset]
				if result.Status == academic.DataStatusMissing || result.Status == academic.DataStatusNeedsRefresh {
					results[dataset] = personalContextUnavailable(academic.DataStatusFailed, "联网刷新权限服务暂时不可用，请稍后重试")
				}
			}
			return nil
		}
		if refreshDenied {
			for _, dataset := range request.Datasets {
				result := results[dataset]
				if result.Status == academic.DataStatusMissing || result.Status == academic.DataStatusNeedsRefresh {
					results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 联网刷新教务数据")
				}
			}
			return nil
		}
		if refreshWait != nil {
			return refreshWait
		}
	}
	for _, dataset := range request.Datasets {
		result := results[dataset]
		if result.Status != academic.DataStatusMissing && result.Status != academic.DataStatusNeedsRefresh {
			continue
		}
		toolName, required, arguments, ok := deviceRequestForDataset(dataset, request)
		if !ok {
			continue
		}
		job, err := mcp.deviceJobs.ScheduleDeviceJob(ctx, DeviceJobRequest{
			UserID: userID, RunID: call.RunID, ToolCallID: call.CallID, ToolName: toolName,
			Arguments: arguments, RequiredDataTypes: required, ExpiresAt: time.Now().Add(2 * time.Minute),
		})
		if err != nil || strings.TrimSpace(job.ID) == "" {
			// 无在线设备时继续返回原结果，由模型据实说明，不伪造等待状态。
			return nil
		}
		return &ToolWait{
			State: models.AIRunStateWaitingDevice, EventType: "device.waiting", ResumeKey: job.ID,
			Payload: map[string]interface{}{"datasets": []string{string(dataset)}, "reason": request.Reason},
		}
	}
	return nil
}

func deviceRequestForDataset(dataset academic.DatasetType, request academic.ResolveContextRequest) (string, []string, json.RawMessage, bool) {
	ensureFresh := request.Freshness == academic.FreshnessRequireFresh
	switch dataset {
	case academic.DatasetGrades:
		if ensureFresh {
			return "device.academic.ensure_fresh_grade_summary", []string{"grades"}, json.RawMessage(`{"max_age_seconds":300}`), true
		}
		return "device.academic.get_cached_grade_summary", []string{"grades"}, json.RawMessage(`{}`), true
	case academic.DatasetSchedule:
		if ensureFresh {
			arguments, err := json.Marshal(map[string]interface{}{
				"week_containing": request.ScheduleWeekContaining,
				"max_age_seconds": 600,
			})
			if err != nil {
				return "", nil, nil, false
			}
			return "device.schedule.ensure_fresh_week", []string{"schedule"}, arguments, true
		}
		arguments, err := json.Marshal(map[string]string{"week_containing": request.ScheduleWeekContaining})
		if err != nil {
			return "", nil, nil, false
		}
		return "device.schedule.get_cached_week", []string{"schedule"}, arguments, true
	case academic.DatasetAcademicSituation:
		if ensureFresh {
			return "device.academic.ensure_fresh_risk_context", []string{"grades"}, json.RawMessage(`{"max_age_seconds":300}`), true
		}
		return "device.academic.get_cached_risk_context", []string{"grades"}, json.RawMessage(`{}`), true
	case academic.DatasetCreditRequirements, academic.DatasetCreditSummary:
		if ensureFresh {
			return "device.academic.ensure_fresh_credit_summary", []string{"academic"}, json.RawMessage(`{"max_age_seconds":300}`), true
		}
		return "device.academic.get_credit_summary", []string{"academic"}, json.RawMessage(`{}`), true
	case academic.DatasetErke:
		if ensureFresh {
			return "device.erke.ensure_fresh_overview", []string{"erke"}, json.RawMessage(`{"max_age_seconds":1800}`), true
		}
		return "device.erke.get_cached_overview", []string{"erke"}, json.RawMessage(`{}`), true
	default:
		return "", nil, nil, false
	}
}

func deviceDatasetForTool(toolName string) string {
	switch toolName {
	case "device.academic.get_cached_grade_summary",
		"device.academic.ensure_fresh_grade_summary",
		"device.academic.get_cached_overview",
		"device.academic.ensure_fresh_overview":
		return string(academic.DatasetGrades)
	case "device.academic.get_cached_risk_context", "device.academic.ensure_fresh_risk_context":
		return string(academic.DatasetAcademicSituation)
	case "device.schedule.get_cached_week", "device.schedule.ensure_fresh_week":
		return string(academic.DatasetSchedule)
	case "device.academic.get_credit_summary", "device.academic.ensure_fresh_credit_summary":
		return string(academic.DatasetCreditRequirements)
	case "device.erke.get_cached_overview", "device.erke.ensure_fresh_overview":
		return string(academic.DatasetErke)
	default:
		return ""
	}
}

func (mcp *campusMCP) resolveSnapshots(ctx context.Context, userID uint, request academic.ResolveContextRequest) (map[academic.DatasetType]academic.ContextResult, *ToolWait, error) {
	if userID == 0 {
		return nil, nil, errors.New("mcp_not_configured")
	}
	results := make(map[academic.DatasetType]academic.ContextResult, len(request.Datasets))
	wait, denied, err := mcp.requirePermission(ctx, userID, models.AIUserPermissionPersonalDataAccess, request.Reason)
	if err != nil {
		for _, dataset := range request.Datasets {
			results[dataset] = personalContextUnavailable(academic.DataStatusFailed, "权限服务暂时不可用，请稍后重试")
		}
		return results, nil, nil
	}
	if wait != nil {
		return nil, wait, nil
	}
	if denied {
		for _, dataset := range request.Datasets {
			results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 的个人数据访问")
		}
		return results, nil, nil
	}
	needsAcademicSnapshot := false
	for _, dataset := range request.Datasets {
		if dataset != academic.DatasetErke {
			needsAcademicSnapshot = true
			break
		}
	}
	var generation uint
	var generationErr error
	if needsAcademicSnapshot {
		wait, cloudDenied, permissionErr := mcp.requirePermission(ctx, userID, models.AIUserPermissionAcademicCloudStorage, request.Reason)
		if permissionErr != nil {
			return nil, nil, permissionErr
		}
		if wait != nil {
			return nil, wait, nil
		}
		if cloudDenied {
			for _, dataset := range request.Datasets {
				if dataset != academic.DatasetErke {
					results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 读取服务端学业快照")
				}
			}
		} else if mcp.snapshots == nil {
			generationErr = errors.New("mcp_not_configured")
		} else {
			generation, generationErr = mcp.snapshots.CurrentCredentialGeneration(ctx, userID)
		}
	}
	for _, dataset := range request.Datasets {
		if _, blocked := results[dataset]; blocked {
			continue
		}
		if resumed, ok := resumedDeviceContextResult(ctx, dataset); ok {
			results[dataset] = resumed
			continue
		}
		if dataset == academic.DatasetErke {
			results[dataset] = mcp.resolveErkeSnapshot(ctx, userID, request.Freshness)
			continue
		}
		if generationErr != nil {
			results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "教务授权不可用，无法读取个人数据")
			continue
		}
		lookup, lookupErr := mcp.snapshots.LookupLatest(ctx, userID, dataset, generation)
		if lookupErr != nil {
			results[dataset] = personalContextUnavailable(academic.DataStatusCorrupted, "个人快照校验失败，不能用于回答")
			continue
		}
		if !lookup.Found {
			results[dataset] = personalContextUnavailable(academic.DataStatusMissing, "服务端没有可用快照；可授权读取设备缓存或刷新教务数据")
			continue
		}
		result := lookup.Result
		if request.Freshness == academic.FreshnessRequireFresh && result.IsStale {
			result.Status = academic.DataStatusNeedsRefresh
			result.Warnings = append(result.Warnings, "该问题要求最新数据，需要刷新后再分析")
		}
		results[dataset] = result
	}
	return results, mcp.waitForPersonalContext(ctx, userID, request, results), nil
}

func (mcp *campusMCP) resolveErkeSnapshot(ctx context.Context, userID uint, freshness academic.FreshnessPreference) academic.ContextResult {
	if mcp.personalSnapshots == nil {
		return personalContextUnavailable(academic.DataStatusMissing, "没有已授权上传的二课快照；请在手机更新二课后选择上传")
	}
	lookup, err := mcp.personalSnapshots.LookupErke(ctx, userID)
	if err != nil || lookup.Corrupted {
		return personalContextUnavailable(academic.DataStatusCorrupted, "二课快照校验失败，不能用于回答")
	}
	if !lookup.Found {
		return personalContextUnavailable(academic.DataStatusMissing, "没有已授权上传的二课快照；请在手机更新二课后选择上传")
	}
	result := lookup.Result
	if freshness == academic.FreshnessRequireFresh && result.IsStale {
		result.Status = academic.DataStatusNeedsRefresh
		result.Warnings = append(result.Warnings, "该问题要求最新二课数据，需要在手机更新后重新上传")
	}
	return result
}

// resumedDeviceContextResult 将设备任务结果还原为统一 ContextResult，
// 但只供当前外层工具重试时读取。它不改变 Snapshot Store，也不绕过权限检查；
// 下一次完整工具执行仍会重新构建分析输入并产出自己的 Tool Result。
func resumedDeviceContextResult(ctx context.Context, dataset academic.DatasetType) (academic.ContextResult, bool) {
	resume, ok := currentDeviceJobResumeContext(ctx)
	if !ok || resume.Dataset != string(dataset) {
		return academic.ContextResult{}, false
	}
	if resume.Status != models.DeviceToolJobCompleted || !json.Valid(resume.Result) {
		return personalContextUnavailable(academic.DataStatusFailed, "手机未能获取可用于本次分析的最新数据"), true
	}
	var envelope struct {
		Data      json.RawMessage     `json:"data"`
		Source    academic.DataSource `json:"source"`
		FetchedAt *time.Time          `json:"fetched_at"`
		ExpiresAt *time.Time          `json:"expires_at"`
		IsStale   bool                `json:"is_stale"`
		IsPartial bool                `json:"is_partial"`
		Warnings  []string            `json:"warnings"`
		Evidence  []academic.Evidence `json:"evidence"`
	}
	if err := json.Unmarshal(resume.Result, &envelope); err != nil || len(envelope.Data) == 0 || !json.Valid(envelope.Data) {
		return personalContextUnavailable(academic.DataStatusFailed, "手机返回的数据格式无法用于本次分析"), true
	}
	source := envelope.Source
	if !source.Valid() || source == academic.DataSourceNone {
		source = academic.DataSourceDeviceEncryptedCache
	}
	status := academic.DataStatusAvailable
	if envelope.IsStale {
		status = academic.DataStatusStale
	} else if envelope.IsPartial {
		status = academic.DataStatusPartial
	}
	evidence := envelope.Evidence
	if len(evidence) == 0 {
		evidence = []academic.Evidence{{
			Source: source, Dataset: dataset, FetchedAt: envelope.FetchedAt,
			ExpiresAt: envelope.ExpiresAt, IsStale: envelope.IsStale,
		}}
	}
	return academic.ContextResult{
		Data: envelope.Data, Status: status, Source: source,
		FetchedAt: envelope.FetchedAt, ExpiresAt: envelope.ExpiresAt,
		IsStale: envelope.IsStale, IsPartial: envelope.IsPartial,
		Warnings: envelope.Warnings, Evidence: evidence,
	}, true
}

func personalContextUnavailable(status academic.DataStatus, warning string) academic.ContextResult {
	return academic.ContextResult{Data: json.RawMessage(`{"error_code":"personal_context_unavailable"}`), Status: status, Source: academic.DataSourceNone, Warnings: []string{warning}, Evidence: make([]academic.Evidence, 0)}
}

func (mcp *campusMCP) getGradeSummary(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	policy := ResolveFreshnessPolicy("grade_summary", []academic.DatasetType{academic.DatasetGrades}, "")
	results, wait, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: policy.Preference, Reason: "grade_summary"})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	result := results[academic.DatasetGrades]
	if !usablePersonalResult(result) {
		return result, nil
	}
	summary := summarizeGrades(result.Data)
	return personalToolResult(summary, result), nil
}

func (mcp *campusMCP) getCreditSummary(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	results, wait, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetCreditRequirements, academic.DatasetAcademicSituation}, Freshness: academic.FreshnessPreferRecent, Reason: "credit_summary"})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	primary := results[academic.DatasetCreditRequirements]
	secondary := results[academic.DatasetAcademicSituation]
	if usablePersonalResult(primary) {
		return personalToolResult(extractCreditFields(primary.Data), primary), nil
	}
	if usablePersonalResult(secondary) {
		return personalToolResult(extractCreditFields(secondary.Data), secondary), nil
	}
	return CampusToolResult{Data: map[string]academic.ContextResult{"credit_requirements": primary, "academic_situation": secondary}, Status: academic.DataStatusMissing, Source: academic.DataSourceNone, Warnings: []string{"没有可用的学分摘要快照"}, Evidence: make([]CampusToolEvidence, 0)}, nil
}

func (mcp *campusMCP) getFailureRisk(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	policy := ResolveFreshnessPolicy("failure_risk", []academic.DatasetType{academic.DatasetGrades}, "")
	results, wait, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: policy.Preference, Reason: "failure_risk"})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	result := results[academic.DatasetGrades]
	if !usablePersonalResult(result) {
		return result, nil
	}
	summary := summarizeGrades(result.Data)
	return personalToolResult(map[string]interface{}{"failed_course_count": summary.FailedCourseCount, "failed_credits": summary.FailedCredits, "unknown_grade_count": summary.UnknownGradeCount, "course_count": summary.CourseCount}, result), nil
}

// getRiskAnalysis 是综合学业分析的唯一入口。它把跨数据集的事实一次性读取并
// 计算风险，避免模型只拿到一门成绩就给出“总体风险不大”之类的越界结论。
func (mcp *campusMCP) getRiskAnalysis(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	requested := []academic.DatasetType{
		academic.DatasetGrades,
		academic.DatasetCreditRequirements,
		academic.DatasetAcademicSituation,
		academic.DatasetErke,
	}
	policy := ResolveFreshnessPolicy("academic_risk_analysis", requested, "")
	results, wait, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{
		Datasets: requested, Freshness: policy.Preference, Reason: "academic_risk_analysis",
	})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	data, warnings := buildAcademicRiskAnalysis(results, requested)
	return aggregatePersonalToolResult(data, results, warnings), nil
}

func (mcp *campusMCP) getScheduleAvailability(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Week           int    `json:"week"`
		Weekdays       []int  `json:"weekdays"`
		WeekContaining string `json:"schedule_week_containing"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.Week < 1 || input.Week > 30 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if _, err := time.Parse("2006-01-02", input.WeekContaining); err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	if len(input.Weekdays) == 0 {
		input.Weekdays = []int{1, 2, 3, 4, 5, 6, 7}
	}
	if !validWeekdays(input.Weekdays) {
		return nil, errors.New("invalid_tool_arguments")
	}
	policy := ResolveFreshnessPolicy("schedule_availability", []academic.DatasetType{academic.DatasetSchedule}, "")
	results, wait, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetSchedule}, Freshness: policy.Preference, Reason: "schedule_availability", ScheduleWeekContaining: input.WeekContaining})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	result := results[academic.DatasetSchedule]
	if !usablePersonalResult(result) {
		return result, nil
	}
	maxPeriod, err := mcp.scheduleMaxPeriod(ctx, input.WeekContaining)
	if err != nil {
		return personalContextUnavailable(academic.DataStatusFailed, "缺少当前生效的节次配置，不能安全计算空闲时间"), nil
	}
	return personalToolResult(scheduleAvailability(result.Data, input.Week, input.Weekdays, maxPeriod), result), nil
}

func (mcp *campusMCP) getErkeOverview(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	results, wait, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetErke}, Freshness: academic.FreshnessPreferRecent, Reason: "erke_overview"})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	result := results[academic.DatasetErke]
	if !usablePersonalResult(result) {
		result.Warnings = append(result.Warnings, "二课数据只能由手机更新并经用户授权上传")
		return result, nil
	}
	return personalToolResult(extractErkeOverview(result.Data), result), nil
}

func (mcp *campusMCP) getAcademicIdentity(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	wait, denied, err := mcp.requirePermission(ctx, userID, models.AIUserPermissionPersonalDataAccess, "academic_identity")
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	if denied {
		return personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 的个人数据访问"), nil
	}
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	var user models.User
	if err := mcp.db.WithContext(ctx).Select("id", "edu_grade", "edu_college", "edu_major", "updated_at").First(&user, userID).Error; err != nil {
		return nil, err
	}
	updatedAt := user.UpdatedAt
	return CampusToolResult{Data: map[string]string{"entry_year": user.EduGrade, "college": user.EduCollege, "major": user.EduMajor}, Status: academic.DataStatusAvailable, Source: academic.DataSourceServerSnapshot, FetchedAt: &updatedAt, IsStale: false, IsPartial: user.EduGrade == "" || user.EduCollege == "" || user.EduMajor == "", Warnings: make([]string, 0), Evidence: []CampusToolEvidence{{Source: academic.DataSourceServerSnapshot, Title: "已授权学业身份", FetchedAt: &updatedAt}}}, nil
}

func requireEmptyArguments(arguments json.RawMessage) error {
	var input map[string]interface{}
	if err := decodeToolArguments(arguments, &input); err != nil || len(input) != 0 {
		return errors.New("invalid_tool_arguments")
	}
	return nil
}
func usablePersonalResult(result academic.ContextResult) bool {
	return result.Status == academic.DataStatusAvailable || result.Status == academic.DataStatusStale || result.Status == academic.DataStatusPartial
}

func personalToolResult(data interface{}, result academic.ContextResult) CampusToolResult {
	evidence := make([]CampusToolEvidence, 0, len(result.Evidence))
	for _, item := range result.Evidence {
		evidence = append(evidence, CampusToolEvidence{Source: item.Source, Dataset: item.Dataset, FetchedAt: item.FetchedAt, ExpiresAt: item.ExpiresAt, IsStale: item.IsStale})
	}
	return CampusToolResult{Data: data, Status: result.Status, Source: result.Source, FetchedAt: result.FetchedAt, ExpiresAt: result.ExpiresAt, IsStale: result.IsStale, IsPartial: result.IsPartial, Warnings: result.Warnings, Evidence: evidence}
}

type gradeSummary struct {
	CourseCount       int      `json:"course_count"`
	TotalCredits      float64  `json:"total_credits"`
	WeightedGPA       float64  `json:"weighted_gpa"`
	FailedCourseCount int      `json:"failed_course_count"`
	FailedCredits     float64  `json:"failed_credits"`
	UnknownGradeCount int      `json:"unknown_grade_count"`
	FailedCourses     []string `json:"failed_courses"`
	CoveredTerms      []string `json:"covered_terms"`
}

func summarizeGrades(raw json.RawMessage) gradeSummary {
	data := decodeJSONObject(raw)
	values, _ := data["grades"].([]interface{})
	selected := selectBestGradeRecords(values)
	summary := gradeSummary{CourseCount: len(selected), FailedCourses: make([]string, 0), CoveredTerms: make([]string, 0)}
	if terms, ok := data["covered_terms"].([]interface{}); ok {
		for _, rawTerm := range terms {
			term, ok := rawTerm.(map[string]interface{})
			if !ok {
				continue
			}
			if scope := firstString(term, "scope_key"); scope != "" {
				summary.CoveredTerms = append(summary.CoveredTerms, academicTermLabel(scope))
				continue
			}
			year := firstString(term, "year")
			semester, semesterOK := jsonNumber(term["semester"])
			if year != "" && semesterOK {
				summary.CoveredTerms = append(summary.CoveredTerms, academicTermLabel(fmt.Sprintf("%s:%d", year, int(semester))))
			}
		}
	}
	var weightedPoints float64
	for _, item := range selected {
		credits, creditOK := jsonNumber(item["credits"])
		gpa, gpaOK := jsonNumber(item["gpa"])
		if creditOK {
			summary.TotalCredits += credits
		}
		if creditOK && gpaOK {
			weightedPoints += credits * gpa
		}
		if gradeFailed(item) {
			summary.FailedCourseCount++
			if creditOK {
				summary.FailedCredits += credits
			}
			if name := firstString(item, "course_name", "name", "title"); name != "" {
				summary.FailedCourses = append(summary.FailedCourses, name)
			}
		}
		if !gradeKnown(item) {
			summary.UnknownGradeCount++
		}
	}
	if summary.TotalCredits > 0 {
		summary.WeightedGPA = roundToolNumber(weightedPoints / summary.TotalCredits)
	}
	summary.TotalCredits = roundToolNumber(summary.TotalCredits)
	summary.FailedCredits = roundToolNumber(summary.FailedCredits)
	return summary
}

func academicTermLabel(scope string) string {
	parts := strings.Split(strings.TrimSpace(scope), ":")
	if len(parts) != 2 {
		return strings.TrimSpace(scope)
	}
	semester, err := strconv.Atoi(parts[1])
	if err != nil {
		return strings.TrimSpace(scope)
	}
	semesterLabel := map[int]string{3: "第一学期", 12: "第二学期"}[semester]
	if semesterLabel == "" {
		return strings.TrimSpace(scope)
	}
	return strings.TrimSpace(parts[0]) + " " + semesterLabel
}

// selectBestGradeRecords 合并跨学期成绩时只保留每门课程的最佳有效记录。
// 教务系统可能同时返回首次成绩、补考和重修记录；全部累加会重复计算学分，
// 也会把已经通过的课程继续当成挂科风险。
func selectBestGradeRecords(values []interface{}) []map[string]interface{} {
	selected := make([]map[string]interface{}, 0, len(values))
	indexes := make(map[string]int, len(values))
	for index, raw := range values {
		item, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		key := firstString(item, "course_id", "course_code")
		if key == "" {
			key = normalizeGradeCourseName(firstString(item, "course_name", "name", "title"))
		}
		if key == "" {
			key = fmt.Sprintf("__row_%d", index)
		}
		if existingIndex, exists := indexes[key]; exists {
			if shouldReplaceGradeRecord(selected[existingIndex], item) {
				selected[existingIndex] = item
			}
			continue
		}
		indexes[key] = len(selected)
		selected = append(selected, item)
	}
	return selected
}

func normalizeGradeCourseName(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	return strings.Map(func(r rune) rune {
		switch r {
		case ' ', '\t', '\r', '\n', '·', '・', '-', '_', '—':
			return -1
		default:
			return r
		}
	}, value)
}

func shouldReplaceGradeRecord(existing, candidate map[string]interface{}) bool {
	existingPassed, existingKnown := gradePassState(existing)
	candidatePassed, candidateKnown := gradePassState(candidate)
	if candidateKnown && existingKnown && candidatePassed != existingPassed {
		return candidatePassed
	}
	if candidateScore, ok := gradeScore(candidate); ok {
		if existingScore, existingOK := gradeScore(existing); existingOK && candidateScore != existingScore {
			return candidateScore > existingScore
		}
	}
	// 快照按 fetched_at 倒序合并；相同成绩保留先出现的最新记录。
	return false
}

func gradePassState(item map[string]interface{}) (bool, bool) {
	if passed, ok := item["passed"].(bool); ok {
		return passed, true
	}
	text := academicGradeText(item)
	switch text {
	case "优秀", "良好", "中等", "合格", "及格", "通过":
		return true, true
	case "不及格", "不合格", "未通过", "缺考", "旷考", "作弊":
		return false, true
	}
	if score, ok := gradeScore(item); ok {
		return score >= 60, true
	}
	return false, false
}

func gradeScore(item map[string]interface{}) (float64, bool) {
	text := academicGradeText(item)
	if text != "" {
		if score, err := strconv.ParseFloat(text, 64); err == nil && score >= 0 && score <= 100 {
			return score, true
		}
	}
	for _, key := range []string{"fraction", "score"} {
		if score, ok := jsonNumber(item[key]); ok && score >= 0 && score <= 100 {
			return score, true
		}
	}
	return 0, false
}

func academicGradeText(item map[string]interface{}) string {
	for _, key := range []string{"grade", "effective_grade", "score_text"} {
		value, ok := item[key]
		if !ok || value == nil {
			continue
		}
		text := strings.TrimSpace(fmt.Sprint(value))
		if text != "" && text != "<nil>" && text != "--" && text != "未录入" && text != "缓考" {
			return text
		}
	}
	return ""
}

func buildAcademicRiskAnalysis(results map[academic.DatasetType]academic.ContextResult, requested []academic.DatasetType) (map[string]interface{}, []string) {
	data := map[string]interface{}{
		"coverage":   make(map[string]string, len(requested)),
		"risks":      make([]string, 0),
		"actions":    make([]string, 0),
		"to_confirm": make([]string, 0),
	}
	warnings := make([]string, 0)
	coverage := data["coverage"].(map[string]string)
	risks := data["risks"].([]string)
	actions := data["actions"].([]string)
	toConfirm := data["to_confirm"].([]string)
	usableCount := 0
	incompleteData := false

	grades := results[academic.DatasetGrades]
	coverage[string(academic.DatasetGrades)] = string(grades.Status)
	if usablePersonalResult(grades) {
		usableCount++
		summary := summarizeGrades(grades.Data)
		data["grades"] = summary
		if grades.IsStale {
			incompleteData = true
			toConfirm = append(toConfirm, "成绩快照已过期，最新变动请先刷新教务数据后再核对")
		}
		if grades.IsPartial {
			incompleteData = true
			toConfirm = append(toConfirm, "成绩快照覆盖不完整，不能据此断言全部学期没有风险")
		}
		if summary.FailedCourseCount > 0 {
			risk := fmt.Sprintf("发现 %d 门未通过课程", summary.FailedCourseCount)
			if len(summary.FailedCourses) > 0 {
				risk += "（" + strings.Join(summary.FailedCourses, "、") + "）"
			}
			risks = append(risks, risk)
			actions = append(actions, "核对未通过课程的补考或重修安排，并记录当期通知的截止时间")
		}
		if summary.UnknownGradeCount > 0 {
			risks = append(risks, fmt.Sprintf("有 %d 门课程缺少最终成绩或通过状态", summary.UnknownGradeCount))
			toConfirm = append(toConfirm, "补齐未知成绩课程的最终成绩和通过状态")
		}
	} else {
		warnings = append(warnings, grades.Warnings...)
		toConfirm = append(toConfirm, "刷新或授权读取成绩快照后再判断挂科风险")
	}

	creditCandidates := []academic.DatasetType{academic.DatasetCreditRequirements, academic.DatasetAcademicSituation}
	credit := map[string]interface{}{}
	creditAvailable := false
	for _, dataset := range creditCandidates {
		result := results[dataset]
		coverage[string(dataset)] = string(result.Status)
		if usablePersonalResult(result) {
			usableCount++
			if result.IsStale || result.IsPartial {
				incompleteData = true
			}
			if len(credit) == 0 || (len(credit) == 1 && credit["available"] == true) {
				credit = extractCreditFields(result.Data)
			}
			creditAvailable = true
		} else {
			warnings = append(warnings, result.Warnings...)
		}
	}
	if creditAvailable {
		data["credits"] = credit
		if gap, ok := jsonNumber(credit["credit_gap"]); ok && gap > 0 {
			risks = append(risks, fmt.Sprintf("按当前快照还差 %g 学分", gap))
			actions = append(actions, "按培养方案拆分剩余学分，优先确认必修课和毕业审核要求")
		} else if earned, earnedOK := jsonNumber(credit["earned_credits"]); earnedOK {
			if required, requiredOK := jsonNumber(credit["required_credits"]); requiredOK && required-earned > 0 {
				gap := roundToolNumber(required - earned)
				credit["credit_gap"] = gap
				risks = append(risks, fmt.Sprintf("按当前快照还差 %g 学分", gap))
				actions = append(actions, "按培养方案拆分剩余学分，优先确认必修课和毕业审核要求")
			}
		}
	} else {
		toConfirm = append(toConfirm, "确认服务端是否有当前培养方案和学分要求快照")
	}

	erke := results[academic.DatasetErke]
	coverage[string(academic.DatasetErke)] = string(erke.Status)
	if usablePersonalResult(erke) {
		usableCount++
		if erke.IsStale || erke.IsPartial {
			incompleteData = true
		}
		overview := extractErkeOverview(erke.Data)
		data["erke"] = overview
		if gap, ok := jsonNumber(overview["graduation_gap"]); ok && gap > 0 {
			risks = append(risks, fmt.Sprintf("二课学分缺口为 %g", gap))
			actions = append(actions, "核对二课认定口径，按缺口类别制定补充计划")
		}
	} else {
		warnings = append(warnings, erke.Warnings...)
		toConfirm = append(toConfirm, "确认二课快照是否已上传及其认定口径")
	}

	data["available_dataset_count"] = usableCount
	data["requested_dataset_count"] = len(requested)
	if len(risks) == 0 && !incompleteData && usableCount >= len(requested) {
		data["risk_level"] = "no_observed_risk"
		toConfirm = append(toConfirm, "毕业学分、必修课和二课要求以学校当期培养方案及教务审核为准")
	} else if incompleteData || usableCount < len(requested) {
		data["risk_level"] = "incomplete"
		toConfirm = append(toConfirm, "当前数据覆盖不完整，不能据此断言整体没有风险")
	} else {
		data["risk_level"] = "observed_risk"
	}
	data["risks"] = uniqueStrings(risks)
	data["actions"] = uniqueStrings(actions)
	data["to_confirm"] = uniqueStrings(toConfirm)
	return data, uniqueStrings(warnings)
}

func aggregatePersonalToolResult(data map[string]interface{}, results map[academic.DatasetType]academic.ContextResult, warnings []string) CampusToolResult {
	combinedWarnings := append([]string{}, warnings...)
	evidence := make([]CampusToolEvidence, 0)
	var source academic.DataSource = academic.DataSourceNone
	var fetchedAt *time.Time
	status := academic.DataStatusMissing
	stale := false
	partial := false
	for _, dataset := range []academic.DatasetType{academic.DatasetGrades, academic.DatasetCreditRequirements, academic.DatasetAcademicSituation, academic.DatasetErke} {
		result := results[dataset]
		if source == academic.DataSourceNone && result.Source.Valid() {
			source = result.Source
		}
		if fetchedAt == nil && result.FetchedAt != nil {
			fetchedAt = result.FetchedAt
		}
		if usablePersonalResult(result) {
			status = result.Status
		} else if status == academic.DataStatusMissing && result.Status != academic.DataStatusMissing {
			status = result.Status
		}
		stale = stale || result.IsStale
		partial = partial || result.IsPartial || !usablePersonalResult(result)
		combinedWarnings = append(combinedWarnings, result.Warnings...)
		for _, item := range result.Evidence {
			evidence = append(evidence, CampusToolEvidence{Source: item.Source, Dataset: item.Dataset, FetchedAt: item.FetchedAt, ExpiresAt: item.ExpiresAt, IsStale: item.IsStale})
		}
	}
	return CampusToolResult{Data: data, Status: status, Source: source, FetchedAt: fetchedAt, IsStale: stale, IsPartial: partial, Warnings: uniqueStrings(combinedWarnings), Evidence: evidence}
}

func uniqueStrings(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func firstString(values map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		if value, ok := values[key].(string); ok && strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func gradeFailed(item map[string]interface{}) bool {
	if passed, ok := item["passed"].(bool); ok {
		return !passed
	}
	value := strings.ToUpper(academicGradeText(item))
	if value == "优秀" || value == "良好" || value == "中等" || value == "合格" || value == "及格" || value == "通过" {
		return false
	}
	if value == "F" || strings.Contains(value, "不及格") || strings.Contains(value, "不合格") || strings.Contains(value, "未通过") || strings.Contains(value, "挂科") {
		return true
	}
	if score, ok := gradeScore(item); ok {
		return score < 60
	}
	return false
}
func gradeKnown(item map[string]interface{}) bool {
	if academicGradeText(item) != "" {
		return true
	}
	if _, ok := jsonNumber(item["fraction"]); ok {
		return true
	}
	return false
}

func extractCreditFields(raw json.RawMessage) map[string]interface{} {
	data := decodeJSONObject(raw)
	result := make(map[string]interface{})
	for _, key := range []string{"total_credits", "earned_credits", "required_credits", "completed_credits", "remaining_credits", "gpa", "warning_level", "graduation_status", "success"} {
		if value, ok := data[key]; ok {
			result[key] = value
		}
	}
	if len(result) == 0 {
		result["available"] = true
	}
	return result
}

func extractErkeOverview(raw json.RawMessage) map[string]interface{} {
	data := decodeJSONObject(raw)
	graduation, _ := data["graduation"].(map[string]interface{})
	yearly, _ := data["yearly"].(map[string]interface{})
	result := make(map[string]interface{})
	// 兼容早期扁平快照，同时优先读取结构化上传接口规定的 graduation/yearly 分组。
	for _, key := range []string{"earned_total", "required_total", "remaining_total", "graduation_gap", "unmet_categories", "official_conclusion"} {
		if value, ok := graduation[key]; ok {
			result[key] = value
		} else if value, ok := data[key]; ok {
			result[key] = value
		}
	}
	for _, key := range []string{"year", "yearly_gap"} {
		if value, ok := yearly[key]; ok {
			result[key] = value
		} else if value, ok := data[key]; ok {
			result[key] = value
		}
	}
	if _, exists := result["official_conclusion"]; !exists {
		if value, ok := yearly["official_conclusion"]; ok {
			result["official_conclusion"] = value
		}
	}
	if activities, ok := data["recent_activities"].([]interface{}); ok {
		result["activity_count"] = len(activities)
	} else if value, ok := data["activity_count"]; ok {
		result["activity_count"] = value
	}
	if len(result) == 0 {
		result["available"] = true
	}
	return result
}

func (mcp *campusMCP) scheduleMaxPeriod(ctx context.Context, date string) (int, error) {
	if mcp.db == nil {
		return 0, errors.New("database_unavailable")
	}
	day, err := time.Parse("2006-01-02", date)
	if err != nil {
		return 0, err
	}
	var profile models.ClassPeriodProfile
	if err := mcp.db.WithContext(ctx).Where("status = ? AND effective_from <= ? AND effective_to >= ?", "published", day, day).Order("published_at DESC, id DESC").First(&profile).Error; err != nil {
		return 0, err
	}
	var periods []struct {
		Section int `json:"section"`
	}
	if err := json.Unmarshal(profile.Periods, &periods); err != nil || len(periods) == 0 {
		return 0, errors.New("period_profile_invalid")
	}
	maxPeriod := 0
	for _, period := range periods {
		if period.Section > maxPeriod {
			maxPeriod = period.Section
		}
	}
	if maxPeriod < 1 || maxPeriod > 30 {
		return 0, errors.New("period_profile_invalid")
	}
	return maxPeriod, nil
}

func scheduleAvailability(raw json.RawMessage, week int, weekdays []int, maxPeriod int) map[string]interface{} {
	data := decodeJSONObject(raw)
	courses, _ := data["courses"].([]interface{})
	occupied := make(map[int]map[int]struct{})
	for _, day := range weekdays {
		occupied[day] = make(map[int]struct{})
	}
	for _, value := range courses {
		item, ok := value.(map[string]interface{})
		if !ok {
			continue
		}
		day, dayOK := jsonInt(item["week_day"])
		if !dayOK || occupied[day] == nil {
			continue
		}
		weeks, _ := item["weeks"].([]interface{})
		applies := len(weeks) == 0
		for _, value := range weeks {
			if number, ok := jsonInt(value); ok && number == week {
				applies = true
				break
			}
		}
		if !applies {
			continue
		}
		start, startOK := jsonInt(item["time"])
		if !startOK {
			continue
		}
		end, endOK := jsonInt(item["end_time"])
		if !endOK || end < start {
			end = start
		}
		for period := start; period <= end && period <= maxPeriod; period++ {
			if period >= 1 {
				occupied[day][period] = struct{}{}
			}
		}
	}
	days := make([]map[string]interface{}, 0, len(weekdays))
	for _, day := range weekdays {
		free := make([]int, 0, maxPeriod)
		for period := 1; period <= maxPeriod; period++ {
			if _, busy := occupied[day][period]; !busy {
				free = append(free, period)
			}
		}
		days = append(days, map[string]interface{}{"weekday": day, "free_periods": free})
	}
	return map[string]interface{}{"week": week, "availability": days}
}

func decodeJSONObject(raw json.RawMessage) map[string]interface{} {
	var result map[string]interface{}
	if json.Unmarshal(raw, &result) != nil || result == nil {
		return map[string]interface{}{}
	}
	return result
}
func jsonNumber(value interface{}) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, true
	case json.Number:
		number, err := typed.Float64()
		return number, err == nil
	case string:
		number, err := strconv.ParseFloat(strings.TrimSpace(typed), 64)
		return number, err == nil
	default:
		return 0, false
	}
}
func jsonInt(value interface{}) (int, bool) {
	number, ok := jsonNumber(value)
	if !ok || number != float64(int(number)) {
		return 0, false
	}
	return int(number), true
}
func roundToolNumber(value float64) float64 { return float64(int(value*100+0.5)) / 100 }
func validWeekdays(values []int) bool {
	seen := make(map[int]struct{}, len(values))
	for _, value := range values {
		if value < 1 || value > 7 {
			return false
		}
		if _, exists := seen[value]; exists {
			return false
		}
		seen[value] = struct{}{}
	}
	return true
}

func mustMarshal(value interface{}) json.RawMessage {
	encoded, _ := json.Marshal(value)
	return encoded
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func toolLimit(arguments json.RawMessage, maximum int) (int, error) {
	var input struct {
		Limit int `json:"limit"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.Limit < 0 || input.Limit > maximum {
		return 0, errors.New("invalid_tool_arguments")
	}
	if input.Limit == 0 {
		input.Limit = maximum
	}
	return input.Limit, nil
}

func competitionSummaries(events []models.CompetitionEvent) []map[string]interface{} {
	result := make([]map[string]interface{}, 0, len(events))
	for _, event := range events {
		result = append(result, competitionSummary(event))
	}
	return result
}
func competitionSummary(event models.CompetitionEvent) map[string]interface{} {
	category := ""
	if event.PrimaryCategory != nil {
		category = event.PrimaryCategory.Name
	}
	return map[string]interface{}{"event_id": event.ID, "title": event.Title, "summary": event.Summary, "category": category, "competition_level": event.CompetitionLevel, "school_recognition": event.SchoolRecognitionStatus, "registration_end": event.RegistrationEnd, "official_url": event.OfficialURL, "status": event.Status}
}
func competitionDetail(event models.CompetitionEvent) map[string]interface{} {
	detail := competitionSummary(event)
	detail["registration_start"] = event.RegistrationStart
	detail["registration_time_text"] = event.RegistrationTimeText
	detail["event_start"] = event.EventStart
	detail["event_end"] = event.EventEnd
	detail["participation_type"] = event.ParticipationType
	detail["team_size_min"] = event.TeamSizeMin
	detail["team_size_max"] = event.TeamSizeMax
	detail["target_audience"] = event.TargetAudience
	detail["school_recognition_grade"] = event.SchoolRecognitionGrade
	detail["notice_url"] = event.NoticeURL
	detail["is_verified"] = event.IsVerified
	return detail
}
func competitionEvidence(events []models.CompetitionEvent) []CampusToolEvidence {
	result := make([]CampusToolEvidence, 0, len(events))
	for _, event := range events {
		updatedAt := event.UpdatedAt
		result = append(result, CampusToolEvidence{Source: academic.DataSourcePublicDatabase, Title: event.Title, URL: event.NoticeURL, FetchedAt: &updatedAt})
	}
	return result
}

func publicResult(data interface{}, source academic.DataSource, evidence []CampusToolEvidence, fetchedAt time.Time) CampusToolResult {
	return CampusToolResult{Data: data, Status: academic.DataStatusAvailable, Source: source, FetchedAt: &fetchedAt, IsStale: false, IsPartial: false, Warnings: make([]string, 0), Evidence: evidence}
}
func publicMissingResult(warning string) CampusToolResult {
	return CampusToolResult{Data: []interface{}{}, Status: academic.DataStatusMissing, Source: academic.DataSourceNone, IsStale: false, IsPartial: false, Warnings: []string{warning}, Evidence: make([]CampusToolEvidence, 0)}
}
func truncateToolText(value string, maxRunes int) string {
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) <= maxRunes {
		return value
	}
	return string(runes[:maxRunes]) + "..."
}
func academicYearInputValid(value string) bool {
	parts := strings.Split(value, "-")
	if len(parts) != 2 || len(parts[0]) != 4 || len(parts[1]) != 4 {
		return false
	}
	start, firstErr := strconv.Atoi(parts[0])
	end, secondErr := strconv.Atoi(parts[1])
	return firstErr == nil && secondErr == nil && end == start+1
}

// 保持编译器对排序依赖的显式约束；赛事比较返回顺序完全由请求 event_ids 决定。
var _ = sort.Ints
