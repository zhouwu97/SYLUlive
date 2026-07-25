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

const campusMCPToolVersion = "2026-07-25"

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
		campusMCPTool{"competition.search_catalog", "按关键词检索当前公开赛事目录。", competitionSearchSchema(), mcp.searchCompetitionCatalog},
		campusMCPTool{"competition.get_details", "读取一项公开赛事的报名、认定和限制条件。", eventIDSchema(), mcp.getCompetitionDetails},
		campusMCPTool{"competition.compare", "比较两到四项公开赛事的报名期限、认定和参与条件。", compareSchema(), mcp.compareCompetitions},
		campusMCPTool{"exam.search_materials", "检索已发布试卷资料的安全元数据，不返回文件内部存储地址。", searchSchema(), mcp.searchExamMaterials},
		campusMCPTool{"community.search_public_posts", "检索公开校园讨论，不返回联系方式或作者私有资料。", searchSchema(), mcp.searchPublicPosts},
		campusMCPTool{"academic.resolve_context", "解析已授权的服务端学业快照，返回来源、更新时间和过期状态。", resolveContextSchema(), mcp.resolveAcademicContext},
		campusMCPTool{"academic.get_grade_summary", "汇总已授权成绩快照中的课程数、学分和绩点。", emptySchema(), mcp.getGradeSummary},
		campusMCPTool{"academic.get_credit_summary", "返回已授权学分要求或学业情况快照中的摘要。", emptySchema(), mcp.getCreditSummary},
		campusMCPTool{"academic.get_failure_risk", "根据已授权成绩快照计算确定性的挂科风险计数。", emptySchema(), mcp.getFailureRisk},
		campusMCPTool{"schedule.get_availability", "根据已授权课表快照计算指定教学周的空闲节次。", availabilitySchema(), mcp.getScheduleAvailability},
		campusMCPTool{"erke.get_overview", "读取用户已授权上传的二课概览；没有上传时明确说明缺失。", emptySchema(), mcp.getErkeOverview},
		campusMCPTool{"profile.get_academic_identity", "读取当前用户已授权的年级、学院和专业，不返回学号或账号信息。", emptySchema(), mcp.getAcademicIdentity},
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
			"datasets":  map[string]interface{}{"type": "array", "minItems": 1, "maxItems": 6, "items": map[string]interface{}{"type": "string", "enum": []string{"grades", "schedule", "academic_situation", "credit_requirements", "credit_summary", "erke"}}},
			"freshness": map[string]interface{}{"type": "string", "enum": []string{"prefer_recent", "require_fresh", "allow_stale"}},
			"reason":    map[string]interface{}{"type": "string", "maxLength": 120},
		}, "required": []string{"datasets", "freshness", "reason"}, "additionalProperties": false,
	}
}

func availabilitySchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"week":     map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 30},
			"weekdays": map[string]interface{}{"type": "array", "minItems": 1, "maxItems": 7, "items": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 7}},
		}, "required": []string{"week"}, "additionalProperties": false,
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
	items, err := mcp.searchKnowledge(ctx, input.Query, input.Limit, nil)
	if err != nil {
		return nil, err
	}
	return publicResult(items, academic.DataSourceKnowledgeBase, knowledgeEvidence(items), mcp.now()), nil
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
	Excerpt      string     `json:"excerpt"`
	SourceURL    string     `json:"source_url,omitempty"`
	PublishedAt  *time.Time `json:"published_at,omitempty"`
}

func (mcp *campusMCP) searchKnowledge(ctx context.Context, query string, limit int, documentTypes []string) ([]knowledgeItem, error) {
	if mcp.db == nil {
		return nil, errors.New("mcp_not_configured")
	}
	pattern := "%" + strings.ToLower(query) + "%"
	db := mcp.db.WithContext(ctx).Model(&models.AIKnowledgeDocument{}).
		Where("status = ?", models.KnowledgeStatusPublished).
		Where("(LOWER(title) LIKE ? OR LOWER(content) LIKE ?)", pattern, pattern)
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
	results, err := mcp.resolveSnapshots(ctx, userID, request)
	if err != nil {
		return nil, err
	}
	if wait := mcp.waitForPersonalContext(ctx, userID, request, results); wait != nil {
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

// waitForPersonalContext 仅在模型明确请求个人数据时创建等待；没有可恢复上下文时保持原有的缺失结果。
func (mcp *campusMCP) waitForPersonalContext(ctx context.Context, userID uint, request academic.ResolveContextRequest, results map[academic.DatasetType]academic.ContextResult) *ToolWait {
	call, hasCall := currentToolCallContext(ctx)
	if !hasCall {
		return nil
	}
	for _, dataset := range request.Datasets {
		result := results[dataset]
		if result.Status == academic.DataStatusPermissionRequired {
			return &ToolWait{
				State: models.AIRunStateWaitingUserConsent, EventType: "consent.required",
				Payload: map[string]interface{}{"datasets": []string{string(dataset)}, "reason": request.Reason},
			}
		}
	}
	if mcp.deviceJobs == nil {
		return nil
	}
	if !mcp.personalAccessAllowed(ctx, userID, models.AIUserPermissionDeviceCacheAccess) {
		for _, dataset := range request.Datasets {
			result := results[dataset]
			if result.Status == academic.DataStatusMissing || result.Status == academic.DataStatusNeedsRefresh {
				results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 读取手机本地缓存")
			}
		}
		return nil
	}
	for _, dataset := range request.Datasets {
		result := results[dataset]
		if result.Status != academic.DataStatusMissing && result.Status != academic.DataStatusNeedsRefresh {
			continue
		}
		toolName, required, arguments, ok := deviceRequestForDataset(dataset)
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

func deviceRequestForDataset(dataset academic.DatasetType) (string, []string, json.RawMessage, bool) {
	switch dataset {
	case academic.DatasetGrades:
		return "device.academic.get_cached_overview", []string{"academic"}, json.RawMessage(`{}`), true
	case academic.DatasetSchedule:
		return "device.schedule.get_cached_week", []string{"schedule"}, json.RawMessage(`{}`), true
	case academic.DatasetAcademicSituation, academic.DatasetCreditRequirements, academic.DatasetCreditSummary:
		return "device.academic.get_credit_summary", []string{"academic"}, json.RawMessage(`{}`), true
	case academic.DatasetErke:
		return "device.erke.get_cached_overview", []string{"erke"}, json.RawMessage(`{}`), true
	default:
		return "", nil, nil, false
	}
}

func (mcp *campusMCP) resolveSnapshots(ctx context.Context, userID uint, request academic.ResolveContextRequest) (map[academic.DatasetType]academic.ContextResult, error) {
	if userID == 0 {
		return nil, errors.New("mcp_not_configured")
	}
	results := make(map[academic.DatasetType]academic.ContextResult, len(request.Datasets))
	if !mcp.personalAccessAllowed(ctx, userID, models.AIUserPermissionPersonalDataAccess) {
		for _, dataset := range request.Datasets {
			results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 的个人数据访问")
		}
		return results, nil
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
		if mcp.snapshots == nil {
			generationErr = errors.New("mcp_not_configured")
		} else {
			generation, generationErr = mcp.snapshots.CurrentCredentialGeneration(ctx, userID)
		}
	}
	for _, dataset := range request.Datasets {
		if dataset == academic.DatasetErke {
			results[dataset] = mcp.resolveErkeSnapshot(ctx, userID, request.Freshness)
			continue
		}
		if !mcp.personalAccessAllowed(ctx, userID, models.AIUserPermissionAcademicCloudStorage) {
			results[dataset] = personalContextUnavailable(academic.DataStatusPermissionRequired, "你已在隐私设置中关闭校园 Agent 读取服务端学业快照")
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
	return results, nil
}

func (mcp *campusMCP) personalAccessAllowed(ctx context.Context, userID uint, scope models.AIUserPermissionScope) bool {
	if mcp.permissions == nil {
		return true
	}
	policy, err := mcp.permissions.Policy(ctx, userID, scope)
	return err == nil && policy != models.AIUserPermissionNever
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

func personalContextUnavailable(status academic.DataStatus, warning string) academic.ContextResult {
	return academic.ContextResult{Data: json.RawMessage(`{"error_code":"personal_context_unavailable"}`), Status: status, Source: academic.DataSourceNone, Warnings: []string{warning}, Evidence: make([]academic.Evidence, 0)}
}

func (mcp *campusMCP) getGradeSummary(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	results, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: academic.FreshnessPreferRecent, Reason: "grade_summary"})
	if err != nil {
		return nil, err
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
	results, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetCreditRequirements, academic.DatasetAcademicSituation}, Freshness: academic.FreshnessPreferRecent, Reason: "credit_summary"})
	if err != nil {
		return nil, err
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
	results, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetGrades}, Freshness: academic.FreshnessPreferRecent, Reason: "failure_risk"})
	if err != nil {
		return nil, err
	}
	result := results[academic.DatasetGrades]
	if !usablePersonalResult(result) {
		return result, nil
	}
	summary := summarizeGrades(result.Data)
	return personalToolResult(map[string]interface{}{"failed_course_count": summary.FailedCourseCount, "failed_credits": summary.FailedCredits, "unknown_grade_count": summary.UnknownGradeCount, "course_count": summary.CourseCount}, result), nil
}

func (mcp *campusMCP) getScheduleAvailability(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input struct {
		Week     int   `json:"week"`
		Weekdays []int `json:"weekdays"`
	}
	if err := decodeToolArguments(arguments, &input); err != nil || input.Week < 1 || input.Week > 30 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if len(input.Weekdays) == 0 {
		input.Weekdays = []int{1, 2, 3, 4, 5, 6, 7}
	}
	if !validWeekdays(input.Weekdays) {
		return nil, errors.New("invalid_tool_arguments")
	}
	results, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetSchedule}, Freshness: academic.FreshnessPreferRecent, Reason: "schedule_availability"})
	if err != nil {
		return nil, err
	}
	result := results[academic.DatasetSchedule]
	if !usablePersonalResult(result) {
		return result, nil
	}
	return personalToolResult(scheduleAvailability(result.Data, input.Week, input.Weekdays), result), nil
}

func (mcp *campusMCP) getErkeOverview(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	if err := requireEmptyArguments(arguments); err != nil {
		return nil, err
	}
	results, err := mcp.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{Datasets: []academic.DatasetType{academic.DatasetErke}, Freshness: academic.FreshnessPreferRecent, Reason: "erke_overview"})
	if err != nil {
		return nil, err
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
	CourseCount       int     `json:"course_count"`
	TotalCredits      float64 `json:"total_credits"`
	WeightedGPA       float64 `json:"weighted_gpa"`
	FailedCourseCount int     `json:"failed_course_count"`
	FailedCredits     float64 `json:"failed_credits"`
	UnknownGradeCount int     `json:"unknown_grade_count"`
}

func summarizeGrades(raw json.RawMessage) gradeSummary {
	data := decodeJSONObject(raw)
	values, _ := data["grades"].([]interface{})
	summary := gradeSummary{CourseCount: len(values)}
	var weightedPoints float64
	for _, value := range values {
		item, ok := value.(map[string]interface{})
		if !ok {
			summary.UnknownGradeCount++
			continue
		}
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

func gradeFailed(item map[string]interface{}) bool {
	if score, ok := jsonNumber(item["fraction"]); ok {
		return score < 60
	}
	value := strings.ToUpper(strings.TrimSpace(fmt.Sprint(item["grade"])))
	return value == "F" || strings.Contains(value, "不及格") || strings.Contains(value, "挂科")
}
func gradeKnown(item map[string]interface{}) bool {
	if _, ok := jsonNumber(item["fraction"]); ok {
		return true
	}
	value := strings.TrimSpace(fmt.Sprint(item["grade"]))
	return value != "" && value != "<nil>"
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

func scheduleAvailability(raw json.RawMessage, week int, weekdays []int) map[string]interface{} {
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
		for period := start; period <= end && period <= 14; period++ {
			if period >= 1 {
				occupied[day][period] = struct{}{}
			}
		}
	}
	days := make([]map[string]interface{}, 0, len(weekdays))
	for _, day := range weekdays {
		free := make([]int, 0, 14)
		for period := 1; period <= 14; period++ {
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
