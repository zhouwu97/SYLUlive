package ai

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/ai/mcpclient"
	"shenliyuan/internal/competitionscope"
	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

const hy3DecisionToolVersion = "2026-07-25"

var hy3DecisionToolNames = []string{
	"hy3_decision.explain_competition_candidates",
	"hy3_decision.compare_competitions",
	"hy3_decision.analyze_academic",
	"hy3_decision.plan_student_week",
}

// hy3DecisionTool 仅公开稳定的 Go 工具名；模型不会直接看见远端 MCP 工具定义。
type hy3DecisionTool struct {
	name        string
	description string
	parameters  map[string]interface{}
	validate    func(json.RawMessage) error
	execute     func(context.Context, uint, json.RawMessage) (interface{}, error)
}

func (tool hy3DecisionTool) Name() string    { return tool.name }
func (tool hy3DecisionTool) Version() string { return hy3DecisionToolVersion }
func (tool hy3DecisionTool) Definition() ToolDefinition {
	return ToolDefinition{Name: tool.name, Description: tool.description, Parameters: tool.parameters}
}
func (tool hy3DecisionTool) Execute(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	return tool.execute(ctx, userID, arguments)
}
func (tool hy3DecisionTool) ValidateToolArguments(arguments json.RawMessage) error {
	if tool.validate == nil {
		return nil
	}
	return tool.validate(arguments)
}

// hy3DecisionMCP 保留本地快照读取和远端 MCP 调用之间的安全边界。
// 任何传入远端的数据都由该类型重新构造，绝不复用模型原始参数中的个人数据。
type hy3DecisionMCP struct {
	db                            *gorm.DB
	remote                        mcpclient.ExternalMCPClient
	campus                        *campusMCP
	competitionCandidates         Hy3CompetitionCandidateBuilder
	competitionExplanationEnabled bool
}

// Hy3CompetitionCandidateBuilder 从统一候选引擎读取当前用户仍可见的候选。
type Hy3CompetitionCandidateBuilder func(
	context.Context,
	uint,
	[]uint,
) ([]dto.CompetitionCandidateDTO, error)

// Hy3DecisionToolOption 仅用于注入已存在的校园数据访问策略，避免适配器依赖具体服务实现。
type Hy3DecisionToolOption func(*hy3DecisionMCP)

// WithHy3DecisionPersonalDataPermissionReader 让 Hy3 适配器遵守与内置校园工具相同的个人数据授权策略。
func WithHy3DecisionPersonalDataPermissionReader(reader PersonalDataPermissionReader) Hy3DecisionToolOption {
	return func(decision *hy3DecisionMCP) {
		if decision != nil && decision.campus != nil {
			decision.campus.permissions = reader
		}
	}
}

// WithHy3CompetitionExplanationEnabled 控制竞赛画像是否允许离开 Go 进程。
func WithHy3CompetitionExplanationEnabled(enabled bool) Hy3DecisionToolOption {
	return func(decision *hy3DecisionMCP) {
		if decision != nil {
			decision.competitionExplanationEnabled = enabled
		}
	}
}

// WithHy3CompetitionCandidateBuilder 注入统一候选引擎，避免 Hy3 适配器自行实现资格和排序规则。
func WithHy3CompetitionCandidateBuilder(builder Hy3CompetitionCandidateBuilder) Hy3DecisionToolOption {
	return func(decision *hy3DecisionMCP) {
		if decision != nil {
			decision.competitionCandidates = builder
		}
	}
}

// NewHy3DecisionTools 创建受控的 Hy3 决策包装工具。
// 该兼容入口假定调用方已完成远端能力校验；生产装配应使用
// NewValidatedHy3DecisionTools，仅注册当前 Session 实际兼容的能力。
func NewHy3DecisionTools(db *gorm.DB, snapshots AcademicSnapshotReader, personalSnapshots PersonalSnapshotReader, remote mcpclient.ExternalMCPClient, options ...Hy3DecisionToolOption) []PureReadTool {
	return newHy3DecisionTools(db, snapshots, personalSnapshots, remote, nil, options...)
}

// NewValidatedHy3DecisionTools 仅注册已通过 MCP tools/list Schema 校验的包装工具。
// 如果某项远端能力缺失或不兼容，模型不会看见对应的 Go 工具。
func NewValidatedHy3DecisionTools(db *gorm.DB, snapshots AcademicSnapshotReader, personalSnapshots PersonalSnapshotReader, remote mcpclient.ExternalMCPClient, definitions []mcpclient.RemoteToolDefinition, options ...Hy3DecisionToolOption) []PureReadTool {
	available := make(map[string]struct{}, len(definitions))
	for _, definition := range definitions {
		available[definition.Name] = struct{}{}
	}
	return newHy3DecisionTools(db, snapshots, personalSnapshots, remote, available, options...)
}

func newHy3DecisionTools(db *gorm.DB, snapshots AcademicSnapshotReader, personalSnapshots PersonalSnapshotReader, remote mcpclient.ExternalMCPClient, available map[string]struct{}, options ...Hy3DecisionToolOption) []PureReadTool {
	if remote == nil {
		return nil
	}
	decision := &hy3DecisionMCP{
		db: db, remote: remote,
		campus:                        &campusMCP{db: db, snapshots: snapshots, personalSnapshots: personalSnapshots, now: time.Now},
		competitionExplanationEnabled: true,
	}
	for _, option := range options {
		if option != nil {
			option(decision)
		}
	}
	tools := make([]PureReadTool, 0, len(hy3DecisionToolNames))
	if decision.competitionExplanationEnabled &&
		decision.competitionCandidates != nil &&
		hy3RemoteToolAvailable(available, "explain_competition_candidates") {
		tools = append(tools, hy3DecisionTool{
			name:        "hy3_decision.explain_competition_candidates",
			description: "解释当前用户已通过规则筛选的赛事候选；不新增赛事、不评分、不重排。",
			parameters:  hy3CandidateExplanationSchema(),
			validate:    validateHy3CandidateExplanationArguments,
			execute:     decision.explainCompetitionCandidates,
		})
	}
	if decision.competitionExplanationEnabled &&
		hy3RemoteToolAvailable(available, "compare_selected_competitions") {
		tools = append(tools, hy3DecisionTool{
			name:        "hy3_decision.compare_competitions",
			description: "比较用户明确选择的已发布赛事；Hy3 只解释公开事实，不评分、不重排。",
			parameters:  hy3CompetitionSchema(),
			validate:    validateHy3CompetitionArguments,
			execute:     decision.compareCompetitions,
		})
	}
	if hy3RemoteToolAvailable(available, "analyze_academic_snapshot") {
		tools = append(tools, hy3DecisionTool{
			name:        "hy3_decision.analyze_academic",
			description: "分析已授权、去身份化的学业与二课快照。",
			parameters:  hy3AcademicSchema(),
			validate:    validateHy3AcademicArguments,
			execute:     decision.analyzeAcademic,
		})
	}
	if hy3RemoteToolAvailable(available, "plan_student_week") {
		tools = append(tools, hy3DecisionTool{
			name:        "hy3_decision.plan_student_week",
			description: "依据已授权课表和已发布节次映射生成受硬约束保护的周计划。",
			parameters:  hy3PlanSchema(),
			validate:    validateHy3PlanArguments,
			execute:     decision.planStudentWeek,
		})
	}
	return tools
}

func hy3RemoteToolAvailable(available map[string]struct{}, name string) bool {
	if available == nil {
		return true
	}
	_, found := available[name]
	return found
}

// requireHy3Permissions 在读取个人画像或快照前完成全部权限检查。
// needsAcademicSnapshot 表示工具会读取服务端成绩或课表快照。
func (decision *hy3DecisionMCP) requireHy3Permissions(ctx context.Context, userID uint, reason string, needsAcademicSnapshot bool) (*ToolWait, models.AIUserPermissionScope, error) {
	if decision == nil || decision.campus == nil {
		return nil, "", errors.New("mcp_not_configured")
	}
	scopes := []models.AIUserPermissionScope{models.AIUserPermissionPersonalDataAccess}
	if needsAcademicSnapshot {
		scopes = append(scopes, models.AIUserPermissionAcademicCloudStorage)
	}
	scopes = append(scopes, models.AIUserPermissionExternalModelAnalysis)
	for _, scope := range scopes {
		wait, denied, err := decision.campus.requirePermission(ctx, userID, scope, reason)
		if err != nil {
			return nil, "", err
		}
		if wait != nil {
			return wait, "", nil
		}
		if denied {
			return nil, scope, nil
		}
	}
	return nil, "", nil
}

func hy3PermissionUnavailable(scope models.AIUserPermissionScope) map[string]interface{} {
	if scope == models.AIUserPermissionExternalModelAnalysis {
		return hy3PersonalUnavailable("你未允许外部模型辅助分析。")
	}
	if scope == models.AIUserPermissionAcademicCloudStorage {
		return hy3PersonalUnavailable("你已在隐私设置中关闭校园 Agent 读取服务端学业快照。")
	}
	return hy3PersonalUnavailable("你已在隐私设置中关闭校园 Agent 的个人数据访问。")
}

func hy3CompetitionSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"event_ids": map[string]interface{}{"type": "array", "minItems": 2, "maxItems": 4, "items": map[string]interface{}{"type": "integer", "minimum": 1}},
			"question":  map[string]interface{}{"type": "string", "maxLength": 500},
		}, "required": []string{"event_ids"}, "additionalProperties": false,
	}
}

func hy3CandidateExplanationSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"event_ids": map[string]interface{}{"type": "array", "minItems": 1, "maxItems": 20, "items": map[string]interface{}{"type": "integer", "minimum": 1}},
			"question":  map[string]interface{}{"type": "string", "maxLength": 500},
		}, "required": []string{"event_ids"}, "additionalProperties": false,
	}
}

func hy3AcademicSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"question":  map[string]interface{}{"type": "string", "maxLength": 500},
			"freshness": map[string]interface{}{"type": "string", "enum": []string{"prefer_recent", "require_fresh", "allow_stale"}},
		}, "additionalProperties": false,
	}
}

func hy3PlanSchema() map[string]interface{} {
	return map[string]interface{}{
		"type": "object", "properties": map[string]interface{}{
			"week": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 30},
			"goals": map[string]interface{}{"type": "array", "maxItems": 50, "items": map[string]interface{}{
				"type": "object", "properties": map[string]interface{}{
					"name":           map[string]interface{}{"type": "string", "minLength": 1, "maxLength": 200},
					"weekly_minutes": map[string]interface{}{"type": "integer", "minimum": 1, "maximum": 10080},
					"priority":       map[string]interface{}{"type": "string", "enum": []string{"high", "medium", "low"}},
				}, "required": []string{"name", "weekly_minutes", "priority"}, "additionalProperties": false,
			}},
			"constraints": map[string]interface{}{"type": "object", "properties": map[string]interface{}{
				"minimum_block_minutes": map[string]interface{}{"type": "integer", "minimum": 15, "maximum": 240},
				"daily_max_minutes":     map[string]interface{}{"type": "integer", "minimum": 15, "maximum": 1000},
				"sleep_start":           map[string]interface{}{"type": "string", "pattern": "^[0-2][0-9]:[0-5][0-9]$"},
				"sleep_end":             map[string]interface{}{"type": "string", "pattern": "^[0-2][0-9]:[0-5][0-9]$"},
			}, "additionalProperties": false},
		}, "required": []string{"week", "goals"}, "additionalProperties": false,
	}
}

type hy3CompetitionInput struct {
	EventIDs []uint `json:"event_ids"`
	Question string `json:"question"`
}

type hy3CandidateExplanationInput struct {
	EventIDs []uint `json:"event_ids"`
	Question string `json:"question"`
}

func validateHy3CandidateExplanationArguments(arguments json.RawMessage) error {
	var input hy3CandidateExplanationInput
	if err := decodeToolArguments(arguments, &input); err != nil {
		return err
	}
	if len(input.EventIDs) < 1 || len(input.EventIDs) > 20 ||
		!uniquePositiveIDs(input.EventIDs) ||
		len([]rune(strings.TrimSpace(input.Question))) > 500 {
		return errors.New("invalid_tool_arguments")
	}
	return nil
}

func validateHy3CompetitionArguments(arguments json.RawMessage) error {
	var input hy3CompetitionInput
	return decodeToolArguments(arguments, &input)
}

func (decision *hy3DecisionMCP) explainCompetitionCandidates(
	ctx context.Context,
	userID uint,
	arguments json.RawMessage,
) (interface{}, error) {
	var input hy3CandidateExplanationInput
	if err := validateHy3CandidateExplanationArguments(arguments); err != nil {
		return nil, err
	}
	if err := decodeToolArguments(arguments, &input); err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	if decision.db == nil || decision.campus == nil || decision.competitionCandidates == nil {
		return hy3Unavailable(mcpclient.ErrorUnavailable, "竞赛候选解释服务暂时不可用。"), nil
	}
	wait, deniedScope, permissionErr := decision.requireHy3Permissions(
		ctx, userID, "hy3_competition_candidate_explanation", false,
	)
	if permissionErr != nil {
		return nil, permissionErr
	}
	if wait != nil {
		return *wait, nil
	}
	if deniedScope != "" {
		return hy3PermissionUnavailable(deniedScope), nil
	}

	candidates, err := decision.competitionCandidates(ctx, userID, input.EventIDs)
	if err != nil {
		return nil, err
	}
	if len(candidates) != len(input.EventIDs) {
		return hy3Unavailable(
			mcpclient.ErrorConstraint,
			"请求的赛事已不在当前候选集合中，请刷新候选后重试。",
		), nil
	}
	profile, err := BuildHy3CompetitionUserContext(ctx, decision.db, userID)
	if err != nil {
		if errors.Is(err, ErrCompetitionAIExplanationDisabled) {
			return hy3PersonalUnavailable("你未允许 AI 解释竞赛匹配。"), nil
		}
		return nil, err
	}

	remoteCandidates := make([]map[string]interface{}, 0, len(candidates))
	competitionIDs := make([]string, 0, len(candidates))
	ruleOrder := make([]int, 0, len(candidates))
	for _, candidate := range candidates {
		if !validHy3RecordHash(candidate.RecordHash) ||
			strings.TrimSpace(candidate.CompetitionID) == "" ||
			!candidate.Gates.CandidatePoolAllowed ||
			candidate.Gates.AIMode != "candidate_explanation" {
			return hy3Unavailable(
				mcpclient.ErrorConstraint,
				"候选目录记录缺少可信摘要或未开放解释权限。",
			), nil
		}
		remoteCandidates = append(remoteCandidates, hy3CandidatePayload(candidate))
		competitionIDs = append(competitionIDs, candidate.CompetitionID)
		ruleOrder = append(ruleOrder, candidate.RuleOrder)
	}
	if unavailable := decision.reserveExternalCall(ctx); unavailable != nil {
		return unavailable, nil
	}
	envelope, unavailable := decision.callRemote(ctx, "explain_competition_candidates", map[string]interface{}{
		"mode":         "candidate_explanation",
		"question":     nullableHy3Text(input.Question, 500),
		"user_context": profile,
		"candidates":   remoteCandidates,
	})
	if unavailable != nil {
		return unavailable, nil
	}
	return map[string]interface{}{
		"status":   "ok",
		"analysis": envelope.Result,
		"deterministic_findings": map[string]interface{}{
			"competition_ids": competitionIDs,
			"rule_order":      ruleOrder,
		},
		"warnings": envelope.Warnings,
	}, nil
}

func hy3CandidatePayload(candidate dto.CompetitionCandidateDTO) map[string]interface{} {
	return map[string]interface{}{
		"competition_id": candidate.CompetitionID,
		"record_hash":    candidate.RecordHash,
		"group_key":      candidate.GroupKey,
		"rule_order":     candidate.RuleOrder,
		"facts": map[string]interface{}{
			"title":                       candidate.Title,
			"competition_level":           candidate.CompetitionLevel,
			"school_recognition_status":   candidate.SchoolRecognitionStatus,
			"school_recognition_grade":    candidate.SchoolRecognitionGrade,
			"competition_rating":          candidate.CompetitionRating,
			"participation_type":          candidate.ParticipationType,
			"team_size_min":               candidate.TeamSizeMin,
			"team_size_max":               candidate.TeamSizeMax,
			"registration_time_text":      candidate.RegistrationTimeText,
			"event_time_text":             candidate.EventTimeText,
			"time_status":                 candidate.TimeStatus,
			"manual_rating_reason_public": candidate.ManualRatingReason,
			"major_fit_summary_public":    candidate.MajorFitSummary,
			"evidence_summary_public":     candidate.EvidenceSummary,
			"evidence_subgrade":           candidate.EvidenceSubgrade,
			"risk_tags":                   candidate.RiskTags,
		},
		"match_dimensions": candidate.MatchDimensions,
		"gates": map[string]interface{}{
			"candidate_pool_allowed":          candidate.Gates.CandidatePoolAllowed,
			"personalized_ranking_allowed":    candidate.Gates.PersonalizedRankingAllowed,
			"strong_recommendation_eligible":  candidate.Gates.StrongRecommendationEligible,
			"recommendation_permission_level": candidate.Gates.PermissionLevel,
			"ai_mode":                         candidate.Gates.AIMode,
		},
	}
}

func (decision *hy3DecisionMCP) compareCompetitions(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input hy3CompetitionInput
	if err := decodeToolArguments(arguments, &input); err != nil || len(input.EventIDs) < 2 || len(input.EventIDs) > 5 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if strings.TrimSpace(input.Question) != "" && len([]rune(input.Question)) > 500 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if !uniquePositiveIDs(input.EventIDs) || len(input.EventIDs) > 4 {
		return nil, errors.New("invalid_tool_arguments")
	}
	if decision.db == nil || decision.campus == nil {
		return hy3Unavailable(mcpclient.ErrorUnavailable, "Hy3 决策服务暂时不可用，请依据已取得的确定性数据回答。"), nil
	}
	wait, deniedScope, permissionErr := decision.requireHy3Permissions(ctx, userID, "hy3_competition_comparison", false)
	if permissionErr != nil {
		return nil, permissionErr
	}
	if wait != nil {
		return *wait, nil
	}
	if deniedScope != "" {
		return hy3PermissionUnavailable(deniedScope), nil
	}

	var events []models.CompetitionEvent
	scope, err := competitionscope.Resolve(ctx, decision.db)
	if err != nil {
		return nil, err
	}
	query := scope.ApplyCandidate(
		decision.db.WithContext(ctx).Model(&models.CompetitionEvent{}).Preload("PrimaryCategory"),
	)
	if err := query.Where("competition_events.id IN ?", input.EventIDs).Find(&events).Error; err != nil {
		return nil, err
	}
	byID := make(map[uint]models.CompetitionEvent, len(events))
	for _, event := range events {
		byID[event.ID] = event
	}
	if len(byID) != len(input.EventIDs) {
		return hy3Unavailable(mcpclient.ErrorConstraint, "请求的赛事不存在或尚未公开，无法生成可信比较。"), nil
	}

	profile, err := BuildHy3CompetitionUserContext(ctx, decision.db, userID)
	if err != nil {
		if errors.Is(err, ErrCompetitionAIExplanationDisabled) {
			return hy3PersonalUnavailable("你未允许 AI 解释竞赛匹配。"), nil
		}
		return nil, err
	}
	candidates := make([]map[string]interface{}, 0, len(input.EventIDs))
	localComparison := make([]map[string]interface{}, 0, len(input.EventIDs))
	for index, id := range input.EventIDs {
		event := byID[id]
		if !validHy3RecordHash(event.RecordHash) || strings.TrimSpace(event.CompetitionID) == "" {
			return hy3Unavailable(
				mcpclient.ErrorConstraint,
				"赛事目录记录缺少稳定标识或摘要，无法进行可信比较。",
			), nil
		}
		category := ""
		if event.PrimaryCategory != nil {
			category = strings.TrimSpace(event.PrimaryCategory.Name)
		}
		candidates = append(candidates, map[string]interface{}{
			"competition_id": event.CompetitionID,
			"record_hash":    event.RecordHash,
			"group_key":      "general_match",
			"rule_order":     index + 1,
			"facts":          hy3SelectedCompetitionFacts(event),
			"match_dimensions": map[string]interface{}{
				"eligibility": "unknown", "major": "unknown", "college": "unknown",
				"grade": "unknown", "goal": "unknown", "direction": "unknown",
				"skill": "unknown", "role": "unknown", "time": "unknown", "training": "unknown",
			},
			"gates": map[string]interface{}{
				"candidate_pool_allowed":          event.CandidatePoolAllowed,
				"personalized_ranking_allowed":    event.PersonalizedRankingAllowed,
				"strong_recommendation_eligible":  event.StrongRecommendationEligible,
				"recommendation_permission_level": defaultHy3Text(event.RecommendationPermissionLevel, "low"),
				"ai_mode":                         defaultHy3Text(event.AIMode, "candidate_explanation"),
			},
		})
		localComparison = append(localComparison, localCompetitionFacts(event, category, profile.WeeklyHours))
	}

	if unavailable := decision.reserveExternalCall(ctx); unavailable != nil {
		return unavailable, nil
	}
	envelope, unavailable := decision.callRemote(ctx, "compare_selected_competitions", map[string]interface{}{
		"mode":         "selected_comparison",
		"question":     nullableHy3Text(input.Question, 500),
		"user_context": profile,
		"competitions": candidates,
	})
	if unavailable != nil {
		return unavailable, nil
	}
	return map[string]interface{}{
		"status":                 "ok",
		"analysis":               envelope.Result,
		"deterministic_findings": map[string]interface{}{"comparisons": localComparison},
		"warnings":               envelope.Warnings,
	}, nil
}

func validHy3RecordHash(value string) bool {
	value = strings.TrimSpace(value)
	if len(value) != 64 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == 32
}

func defaultHy3Text(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}

func hy3SelectedCompetitionFacts(event models.CompetitionEvent) map[string]interface{} {
	riskTags := make([]string, 0)
	if len(event.RiskTags) > 0 {
		_ = json.Unmarshal(event.RiskTags, &riskTags)
	}
	return map[string]interface{}{
		"competition_level":           event.CompetitionLevel,
		"school_recognition_status":   event.SchoolRecognitionStatus,
		"school_recognition_grade":    event.SchoolRecognitionGrade,
		"competition_rating":          event.CompetitionRating,
		"participation_type":          event.ParticipationType,
		"team_size_min":               event.TeamSizeMin,
		"team_size_max":               event.TeamSizeMax,
		"registration_time_text":      event.RegistrationTimeText,
		"event_time_text":             event.EventTimeText,
		"time_status":                 event.TimeStatus,
		"manual_rating_reason_public": event.ManualRatingReasonPublic,
		"major_fit_summary_public":    event.MajorFitSummaryPublic,
		"evidence_summary_public":     event.EvidenceSummaryPublic,
		"evidence_subgrade":           event.EvidenceSubgrade,
		"risk_tags":                   riskTags,
	}
}

func uniquePositiveIDs(values []uint) bool {
	seen := make(map[uint]struct{}, len(values))
	for _, value := range values {
		if value == 0 {
			return false
		}
		if _, exists := seen[value]; exists {
			return false
		}
		seen[value] = struct{}{}
	}
	return true
}

func composeRecognitionNote(event models.CompetitionEvent) string {
	parts := make([]string, 0, 2)
	if value := strings.TrimSpace(event.SchoolRecognitionStatus); value != "" {
		parts = append(parts, "学校认定状态："+value)
	}
	if value := strings.TrimSpace(event.SchoolRecognitionGrade); value != "" {
		parts = append(parts, "认定等级："+value)
	}
	if len(parts) == 0 {
		return "学校认定信息未发布"
	}
	return strings.Join(parts, "；")
}

func competitionDifficulty(event models.CompetitionEvent) string {
	level := strings.ToLower(strings.TrimSpace(event.CompetitionLevel))
	switch {
	case strings.Contains(level, "national") || strings.Contains(level, "国家") || strings.Contains(level, "全国"):
		return "high"
	case strings.Contains(level, "provincial") || strings.Contains(level, "省"):
		return "medium"
	case level != "":
		return "low"
	default:
		return ""
	}
}

func localCompetitionFacts(event models.CompetitionEvent, category string, weeklyHours int) map[string]interface{} {
	recognized := schoolRecognitionConfirmed(event.SchoolRecognitionStatus)
	return map[string]interface{}{
		"name": event.Title,
		"school_recognition": map[string]interface{}{
			"recognized": recognized,
			"level":      nullableHy3Text(event.SchoolRecognitionGrade, 100),
			"note":       composeRecognitionNote(event),
		},
		"human_evaluation": map[string]interface{}{
			"difficulty": nullableHy3Text(competitionDifficulty(event), 30),
			"note":       "难度仅依据已发布赛事级别推导，不代表人工主观评价。",
		},
		"student_fit": map[string]interface{}{
			"available_weekly_hours": weeklyHours,
			"category":               nullableHy3Text(category, 80),
		},
		"evidence_quality": map[string]interface{}{
			"level":       evidenceLevel(event),
			"source_type": "public_database",
			"official":    event.IsVerified,
		},
	}
}

// schoolRecognitionConfirmed 只接受明确的已认定状态，避免将“未认定”误判为已认定。
func schoolRecognitionConfirmed(status string) bool {
	normalized := strings.ToLower(strings.TrimSpace(status))
	switch normalized {
	case "recognized", "approved", "已认定", "认定", "已通过认定", "通过认定":
		return true
	default:
		return false
	}
}

func evidenceLevel(event models.CompetitionEvent) string {
	if event.IsVerified {
		return "verified"
	}
	if strings.TrimSpace(event.OfficialURL) != "" || strings.TrimSpace(event.NoticeURL) != "" {
		return "published_source"
	}
	return "limited"
}

type hy3AcademicInput struct {
	Question  string                       `json:"question"`
	Freshness academic.FreshnessPreference `json:"freshness"`
}

func validateHy3AcademicArguments(arguments json.RawMessage) error {
	var input hy3AcademicInput
	return decodeToolArguments(arguments, &input)
}

func (decision *hy3DecisionMCP) analyzeAcademic(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input hy3AcademicInput
	if err := decodeToolArguments(arguments, &input); err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	if strings.TrimSpace(input.Question) != "" && len([]rune(input.Question)) > 500 {
		return nil, errors.New("invalid_tool_arguments")
	}
	requestedFreshness := input.Freshness
	if requestedFreshness == "" {
		requestedFreshness = academic.FreshnessAllowStale
	}
	if input.Freshness != academic.FreshnessPreferRecent && input.Freshness != academic.FreshnessRequireFresh && input.Freshness != academic.FreshnessAllowStale {
		if requestedFreshness != academic.FreshnessAllowStale {
			return nil, errors.New("invalid_tool_arguments")
		}
	}
	datasets := []academic.DatasetType{academic.DatasetGrades, academic.DatasetCreditRequirements, academic.DatasetAcademicSituation, academic.DatasetErke}
	serverPolicy := ResolveFreshnessPolicy("hy3_academic_analysis", datasets, input.Question)
	input.Freshness = EffectiveFreshness(serverPolicy.Preference, requestedFreshness)
	if decision.campus == nil {
		return hy3Unavailable(mcpclient.ErrorUnavailable, "Hy3 决策服务暂时不可用，请依据已取得的确定性数据回答。"), nil
	}
	wait, deniedScope, permissionErr := decision.requireHy3Permissions(ctx, userID, "hy3_academic_analysis", true)
	if permissionErr != nil {
		return nil, permissionErr
	}
	if wait != nil {
		return *wait, nil
	}
	if deniedScope != "" {
		return hy3PermissionUnavailable(deniedScope), nil
	}
	results, wait, err := decision.campus.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{
		Datasets:  datasets,
		Freshness: input.Freshness,
		Reason:    "hy3_academic_analysis",
	})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	grades := results[academic.DatasetGrades]
	if !usablePersonalResult(grades) {
		return hy3PersonalUnavailableFromResult(grades), nil
	}
	credits := results[academic.DatasetCreditRequirements]
	if !usablePersonalResult(credits) {
		credits = results[academic.DatasetAcademicSituation]
	}
	erke := results[academic.DatasetErke]
	snapshot, warnings, err := buildHy3AcademicSnapshot(grades.Data, credits, erke)
	if err != nil {
		return hy3Unavailable(mcpclient.ErrorConstraint, "学业快照不满足 Hy3 分析所需的安全数据约束。"), nil
	}
	if unavailable := decision.reserveExternalCall(ctx); unavailable != nil {
		return unavailable, nil
	}
	envelope, unavailable := decision.callRemote(ctx, "analyze_academic_snapshot", map[string]interface{}{"snapshot": snapshot})
	if unavailable != nil {
		return unavailable, nil
	}
	findings, err := sanitizeHy3AcademicFindings(envelope.DeterministicFindings)
	if err != nil {
		return hy3Unavailable(mcpclient.ErrorInvalidResult, "Hy3 决策服务返回格式无效，请依据已取得的确定性数据回答。"), nil
	}
	return map[string]interface{}{
		"status":                 "ok",
		"analysis":               envelope.Result,
		"deterministic_findings": findings,
		"warnings":               append(warnings, envelope.Warnings...),
		"source":                 "hy3_mcp",
		"fetched_at":             grades.FetchedAt,
		"expires_at":             grades.ExpiresAt,
		"is_stale":               grades.IsStale,
		"evidence":               contextResultsEvidence(grades, credits, erke),
		"analysis_input":         snapshot,
	}, nil
}

func buildHy3AcademicSnapshot(gradesRaw json.RawMessage, credits academic.ContextResult, erke academic.ContextResult) (map[string]interface{}, []string, error) {
	grades := decodeJSONObject(gradesRaw)
	coursesRaw, coursesOK := grades["grades"].([]interface{})
	projectionOnly := false
	if !coursesOK {
		var err error
		coursesRaw, err = deviceGradeProjectionCourses(grades)
		if err != nil {
			return nil, nil, errors.New("grades_missing")
		}
		projectionOnly = true
	}
	if len(coursesRaw) > 500 {
		return nil, nil, errors.New("too_many_courses")
	}
	selectedCourses := selectBestGradeRecords(coursesRaw)
	courses := make([]map[string]interface{}, 0, len(selectedCourses))
	for _, course := range selectedCourses {
		name := firstHy3String(course, "course_name", "name", "course")
		if name == "" {
			continue
		}
		item := map[string]interface{}{
			"course_name": truncateHy3Text(name, 200),
			"is_required": courseIsRequired(course),
		}
		if value, ok := firstHy3Number(course, "credits", "credit"); ok && value >= 0 && value <= 100 {
			item["credits"] = value
		}
		if passed, ok := course["passed"].(bool); ok {
			item["passed"] = passed
		} else if gradeText := academicGradeText(course); gradeText != "" {
			if score, err := strconv.ParseFloat(gradeText, 64); err == nil && score >= 0 && score <= 100 {
				item["grade"] = score
				item["passed"] = score >= 60
			} else {
				item["grade"] = truncateHy3Text(gradeText, 100)
				if passed, known := gradePassState(course); known {
					item["passed"] = passed
				}
			}
		} else if score, ok := firstHy3Number(course, "fraction", "score"); ok {
			item["grade"] = score
			item["passed"] = score >= 60
		}
		courses = append(courses, item)
	}
	summary := summarizeGrades(gradesRaw)
	if projectionOnly {
		if courseCount, ok := firstHy3Number(grades, "course_count"); ok {
			summary.CourseCount = int(courseCount)
		}
		if earned, ok := firstHy3Number(grades, "earned_credits"); ok {
			summary.TotalCredits = earned
		}
		if weightedGPA, ok := firstHy3Number(grades, "weighted_gpa"); ok {
			summary.WeightedGPA = weightedGPA
		}
		summary.FailedCourses = make([]string, 0, len(coursesRaw))
		for _, rawCourse := range coursesRaw {
			if course, ok := rawCourse.(map[string]interface{}); ok {
				if name := firstHy3String(course, "course_name"); name != "" {
					summary.FailedCourses = append(summary.FailedCourses, name)
				}
			}
		}
		summary.FailedCourseCount = len(summary.FailedCourses)
	}
	earnedCredits := summary.TotalCredits
	requiredCredits := earnedCredits
	warnings := make([]string, 0, 2)
	if projectionOnly {
		warnings = append(warnings, "本次使用了手机返回的成绩风险摘要，未上传完整成绩明细。")
	}
	if usablePersonalResult(credits) {
		creditFields := extractCreditFields(credits.Data)
		if value, ok := firstHy3Number(creditFields, "earned_credits", "completed_credits", "total_credits"); ok {
			earnedCredits = value
		}
		if value, ok := firstHy3Number(creditFields, "required_credits", "total_required_credits"); ok {
			requiredCredits = value
		}
	} else {
		warnings = append(warnings, "没有可用的学分要求快照，已仅按成绩快照分析。")
	}
	erkeEarned, erkeRequired := float64(0), float64(0)
	if usablePersonalResult(erke) {
		erkeFields := extractErkeOverview(erke.Data)
		if value, ok := firstHy3Number(erkeFields, "earned_total", "earned_credits"); ok {
			erkeEarned = value
		}
		if value, ok := firstHy3Number(erkeFields, "required_total", "required_credits"); ok {
			erkeRequired = value
		}
	} else {
		warnings = append(warnings, "没有可用的二课快照，二课缺口未纳入分析。")
	}
	for _, value := range []float64{earnedCredits, requiredCredits, erkeEarned, erkeRequired} {
		if value < 0 || value > 1000 {
			return nil, nil, errors.New("credit_out_of_range")
		}
	}
	return map[string]interface{}{
		"courses":          courses,
		"course_count":     summary.CourseCount,
		"weighted_gpa":     summary.WeightedGPA,
		"earned_credits":   earnedCredits,
		"required_credits": requiredCredits,
		"erke_earned":      erkeEarned,
		"erke_required":    erkeRequired,
	}, warnings, nil
}

// deviceGradeProjectionCourses 将设备侧最小风险投影转换成 Hy3 可接受的受限课程列表。
// 这里只保留未通过课程；完整成绩明细仍不会离开设备。
func deviceGradeProjectionCourses(data map[string]interface{}) ([]interface{}, error) {
	courseCount, ok := firstHy3Number(data, "course_count")
	if !ok || courseCount < 0 || courseCount > 500 {
		return nil, errors.New("projection_course_count_invalid")
	}
	rawFailed, ok := data["failed_courses"].([]interface{})
	if !ok || len(rawFailed) > 500 {
		return nil, errors.New("projection_failed_courses_invalid")
	}
	courses := make([]interface{}, 0, len(rawFailed))
	for _, raw := range rawFailed {
		course, ok := raw.(map[string]interface{})
		if !ok {
			return nil, errors.New("projection_course_invalid")
		}
		name := firstHy3String(course, "course_name")
		if name == "" || len([]rune(name)) > 200 {
			return nil, errors.New("projection_course_name_invalid")
		}
		item := map[string]interface{}{"course_name": name, "passed": false}
		if grade, ok := firstHy3Number(course, "grade"); ok && grade >= 0 && grade <= 100 {
			item["grade"] = grade
		}
		if credits, ok := firstHy3Number(course, "credits"); ok && credits >= 0 && credits <= 100 {
			item["credits"] = credits
		}
		courses = append(courses, item)
	}
	return courses, nil
}

func courseIsRequired(course map[string]interface{}) bool {
	if required, ok := course["is_required"].(bool); ok {
		return required
	}
	value := strings.ToLower(firstHy3String(course, "course_type", "type", "nature"))
	return strings.Contains(value, "required") || strings.Contains(value, "必修")
}

type hy3PlanInput struct {
	Week        int                     `json:"week"`
	Goals       []hy3PlanGoalInput      `json:"goals"`
	Constraints hy3PlanConstraintsInput `json:"constraints"`
}

func validateHy3PlanArguments(arguments json.RawMessage) error {
	var input hy3PlanInput
	return decodeToolArguments(arguments, &input)
}

type hy3PlanGoalInput struct {
	Name          string `json:"name"`
	WeeklyMinutes int    `json:"weekly_minutes"`
	Priority      string `json:"priority"`
}

type hy3PlanConstraintsInput struct {
	MinimumBlockMinutes *int    `json:"minimum_block_minutes"`
	DailyMaxMinutes     *int    `json:"daily_max_minutes"`
	SleepStart          *string `json:"sleep_start"`
	SleepEnd            *string `json:"sleep_end"`
}

type hy3PlanConstraints struct {
	MinimumBlockMinutes int
	DailyMaxMinutes     int
	SleepStart          string
	SleepEnd            string
}

func (constraints hy3PlanConstraints) asRemote() map[string]interface{} {
	return map[string]interface{}{
		"minimum_block_minutes": constraints.MinimumBlockMinutes,
		"daily_max_minutes":     constraints.DailyMaxMinutes,
		"sleep_start":           constraints.SleepStart,
		"sleep_end":             constraints.SleepEnd,
	}
}

func (decision *hy3DecisionMCP) planStudentWeek(ctx context.Context, userID uint, arguments json.RawMessage) (interface{}, error) {
	var input hy3PlanInput
	if err := decodeToolArguments(arguments, &input); err != nil || input.Week < 1 || input.Week > 30 || len(input.Goals) > 50 {
		return nil, errors.New("invalid_tool_arguments")
	}
	goals, err := normalizeHy3Goals(input.Goals)
	if err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	constraints, err := normalizeHy3Constraints(input.Constraints)
	if err != nil {
		return nil, errors.New("invalid_tool_arguments")
	}
	if decision.campus == nil {
		return hy3Unavailable(mcpclient.ErrorUnavailable, "Hy3 决策服务暂时不可用，请依据已取得的确定性数据回答。"), nil
	}
	wait, deniedScope, permissionErr := decision.requireHy3Permissions(ctx, userID, "hy3_week_plan", true)
	if permissionErr != nil {
		return nil, permissionErr
	}
	if wait != nil {
		return *wait, nil
	}
	if deniedScope != "" {
		return hy3PermissionUnavailable(deniedScope), nil
	}
	weekStart, _, err := decision.resolveWeekStart(ctx, json.RawMessage(`{}`), input.Week)
	if err != nil {
		return hy3Unavailable(mcpclient.ErrorConstraint, "缺少已发布校历，不能安全定位请求的教学周。"), nil
	}
	results, wait, err := decision.campus.resolveSnapshots(ctx, userID, academic.ResolveContextRequest{
		Datasets:               []academic.DatasetType{academic.DatasetSchedule},
		Freshness:              academic.FreshnessPreferRecent,
		Reason:                 "hy3_week_plan",
		ScheduleWeekContaining: weekStart.Format("2006-01-02"),
	})
	if err != nil {
		return nil, err
	}
	if wait != nil {
		return *wait, nil
	}
	scheduleSnapshot := results[academic.DatasetSchedule]
	if !usablePersonalResult(scheduleSnapshot) {
		return hy3PersonalUnavailableFromResult(scheduleSnapshot), nil
	}
	schedule, fixedEvents, err := decision.buildWeeklySchedule(ctx, scheduleSnapshot.Data, input.Week)
	if err != nil {
		return hy3Unavailable(mcpclient.ErrorConstraint, "缺少已发布校历或节次映射，不能安全生成周计划。"), nil
	}
	if unavailable := decision.reserveExternalCall(ctx); unavailable != nil {
		return unavailable, nil
	}
	envelope, unavailable := decision.callRemote(ctx, "plan_student_week", map[string]interface{}{
		"schedule":    schedule,
		"goals":       goals,
		"constraints": constraints.asRemote(),
	})
	if unavailable != nil {
		return unavailable, nil
	}
	findings, issues := sanitizeHy3WeekPlan(schedule, fixedEvents, constraints, goals, envelope.DeterministicFindings)
	if len(issues) > 0 {
		return map[string]interface{}{
			"status":     "unavailable",
			"error_code": mcpclient.ErrorConstraint,
			"warnings":   []string{"Hy3 返回的周计划未通过本地硬约束复核，已拒绝使用。"},
			"issues":     issues,
		}, nil
	}
	return map[string]interface{}{
		"status":                 "ok",
		"analysis":               envelope.Result,
		"deterministic_findings": findings,
		"warnings":               envelope.Warnings,
	}, nil
}

func normalizeHy3Goals(values []hy3PlanGoalInput) ([]map[string]interface{}, error) {
	goals := make([]map[string]interface{}, 0, len(values))
	seenNames := make(map[string]struct{}, len(values))
	for _, value := range values {
		name := strings.TrimSpace(value.Name)
		if name == "" || len([]rune(name)) > 200 || value.WeeklyMinutes < 1 || value.WeeklyMinutes > 10080 {
			return nil, errors.New("goal_invalid")
		}
		if _, exists := seenNames[name]; exists {
			return nil, errors.New("goal_duplicate")
		}
		seenNames[name] = struct{}{}
		if value.Priority != "high" && value.Priority != "medium" && value.Priority != "low" {
			return nil, errors.New("goal_priority_invalid")
		}
		goals = append(goals, map[string]interface{}{"name": name, "weekly_minutes": value.WeeklyMinutes, "priority": value.Priority})
	}
	return goals, nil
}

func normalizeHy3Constraints(input hy3PlanConstraintsInput) (hy3PlanConstraints, error) {
	constraints := hy3PlanConstraints{MinimumBlockMinutes: 30, DailyMaxMinutes: 240, SleepStart: "23:30", SleepEnd: "07:00"}
	if input.MinimumBlockMinutes != nil {
		constraints.MinimumBlockMinutes = *input.MinimumBlockMinutes
	}
	if input.DailyMaxMinutes != nil {
		constraints.DailyMaxMinutes = *input.DailyMaxMinutes
	}
	if input.SleepStart != nil {
		constraints.SleepStart = strings.TrimSpace(*input.SleepStart)
	}
	if input.SleepEnd != nil {
		constraints.SleepEnd = strings.TrimSpace(*input.SleepEnd)
	}
	if constraints.MinimumBlockMinutes < 15 || constraints.MinimumBlockMinutes > 240 ||
		constraints.DailyMaxMinutes < 15 || constraints.DailyMaxMinutes > 1000 ||
		constraints.MinimumBlockMinutes > constraints.DailyMaxMinutes ||
		!validHy3Clock(constraints.SleepStart) || !validHy3Clock(constraints.SleepEnd) || constraints.SleepStart == constraints.SleepEnd {
		return hy3PlanConstraints{}, errors.New("constraints_invalid")
	}
	return constraints, nil
}

type hy3CalendarDocument struct {
	AcademicYear string `json:"academic_year"`
	Timezone     string `json:"timezone"`
	Semesters    []struct {
		TeachingWeeks []struct {
			Week      int    `json:"week"`
			StartDate string `json:"start_date"`
			EndDate   string `json:"end_date"`
		} `json:"teaching_weeks"`
	} `json:"semesters"`
}

type hy3ClassPeriod struct {
	Section   int    `json:"section"`
	StartTime string `json:"start_time"`
	EndTime   string `json:"end_time"`
}

type hy3FixedEvent struct {
	Title   string
	Weekday int
	Start   string
	End     string
}

func (decision *hy3DecisionMCP) buildWeeklySchedule(ctx context.Context, raw json.RawMessage, week int) (map[string]interface{}, []hy3FixedEvent, error) {
	if decision.db == nil {
		return nil, nil, errors.New("database_unavailable")
	}
	weekStart, calendar, err := decision.resolveWeekStart(ctx, raw, week)
	if err != nil {
		return nil, nil, err
	}
	periods, err := decision.resolveClassPeriods(ctx, calendar.AcademicYear, weekStart)
	if err != nil {
		return nil, nil, err
	}
	fixedEvents, err := buildHy3FixedEvents(raw, week, periods)
	if err != nil {
		return nil, nil, err
	}
	if issues := validateHy3FixedEvents(fixedEvents); len(issues) > 0 {
		return nil, nil, fmt.Errorf("fixed_events_invalid:%s", strings.Join(issues, ","))
	}
	remoteEvents := make([]map[string]interface{}, 0, len(fixedEvents))
	for _, event := range fixedEvents {
		remoteEvents = append(remoteEvents, map[string]interface{}{
			"title": event.Title, "weekday": event.Weekday, "start": event.Start, "end": event.End,
		})
	}
	return map[string]interface{}{
		"week_start":   weekStart.Format("2006-01-02"),
		"timezone":     calendar.Timezone,
		"fixed_events": remoteEvents,
	}, fixedEvents, nil
}

func (decision *hy3DecisionMCP) resolveWeekStart(ctx context.Context, raw json.RawMessage, week int) (time.Time, hy3CalendarDocument, error) {
	var calendars []models.CampusCalendar
	if err := decision.db.WithContext(ctx).Where("status = ?", "published").Order("academic_year DESC, version DESC, id DESC").Find(&calendars).Error; err != nil {
		return time.Time{}, hy3CalendarDocument{}, err
	}
	if len(calendars) == 0 {
		return time.Time{}, hy3CalendarDocument{}, errors.New("calendar_missing")
	}
	requestedStart, hasRequestedStart := hy3ScheduleWeekStart(raw)
	type match struct {
		start    time.Time
		calendar hy3CalendarDocument
	}
	matches := make([]match, 0, 1)
	for _, record := range calendars {
		var calendar hy3CalendarDocument
		if json.Unmarshal(record.Data, &calendar) != nil || strings.TrimSpace(calendar.Timezone) == "" {
			continue
		}
		if calendar.AcademicYear == "" {
			calendar.AcademicYear = record.AcademicYear
		}
		location, err := time.LoadLocation(calendar.Timezone)
		if err != nil {
			continue
		}
		for _, semester := range calendar.Semesters {
			for _, teachingWeek := range semester.TeachingWeeks {
				if teachingWeek.Week != week {
					continue
				}
				start, err := time.ParseInLocation("2006-01-02", teachingWeek.StartDate, location)
				if err != nil || start.Weekday() != time.Monday {
					continue
				}
				if hasRequestedStart && start.Format("2006-01-02") != requestedStart {
					continue
				}
				matches = append(matches, match{start: start, calendar: calendar})
			}
		}
	}
	if len(matches) != 1 {
		return time.Time{}, hy3CalendarDocument{}, errors.New("week_mapping_ambiguous_or_missing")
	}
	return matches[0].start, matches[0].calendar, nil
}

func hy3ScheduleWeekStart(raw json.RawMessage) (string, bool) {
	data := decodeJSONObject(raw)
	value := strings.TrimSpace(fmt.Sprint(data["week_start"]))
	if value == "" || value == "<nil>" {
		return "", false
	}
	parsed, err := time.Parse("2006-01-02", value)
	if err != nil || parsed.Weekday() != time.Monday {
		return "", false
	}
	return value, true
}

func (decision *hy3DecisionMCP) resolveClassPeriods(ctx context.Context, academicYear string, weekStart time.Time) (map[int]hy3ClassPeriod, error) {
	var profile models.ClassPeriodProfile
	err := decision.db.WithContext(ctx).
		Where("status = ? AND academic_year = ? AND effective_from <= ? AND effective_to >= ?", "published", academicYear, weekStart, weekStart).
		Order("published_at DESC, id DESC").First(&profile).Error
	if err != nil {
		return nil, err
	}
	var periods []hy3ClassPeriod
	if json.Unmarshal(profile.Periods, &periods) != nil || len(periods) == 0 || len(periods) > 30 {
		return nil, errors.New("period_profile_invalid")
	}
	bySection := make(map[int]hy3ClassPeriod, len(periods))
	for _, period := range periods {
		if period.Section < 1 || !validHy3Clock(period.StartTime) || !validHy3Clock(period.EndTime) || hy3ClockMinutes(period.EndTime) <= hy3ClockMinutes(period.StartTime) {
			return nil, errors.New("period_profile_invalid")
		}
		if _, exists := bySection[period.Section]; exists {
			return nil, errors.New("period_profile_invalid")
		}
		bySection[period.Section] = period
	}
	return bySection, nil
}

func buildHy3FixedEvents(raw json.RawMessage, week int, periods map[int]hy3ClassPeriod) ([]hy3FixedEvent, error) {
	data := decodeJSONObject(raw)
	courses, ok := data["courses"].([]interface{})
	if !ok || len(courses) > 200 {
		return nil, errors.New("schedule_courses_invalid")
	}
	events := make([]hy3FixedEvent, 0, len(courses))
	for _, rawCourse := range courses {
		course, ok := rawCourse.(map[string]interface{})
		if !ok {
			return nil, errors.New("schedule_course_invalid")
		}
		applies, err := courseAppliesInWeek(course, week)
		if err != nil {
			return nil, err
		}
		if !applies {
			continue
		}
		weekday, weekdayOK := firstHy3Int(course, "week_day", "weekday", "day_of_week")
		startSection, startOK := firstHy3Int(course, "time", "start_section", "start")
		endSection, endOK := firstHy3Int(course, "end_time", "end_section", "end")
		if !weekdayOK || weekday < 1 || weekday > 7 || !startOK || startSection < 1 {
			return nil, errors.New("schedule_course_invalid")
		}
		if !endOK || endSection < startSection {
			endSection = startSection
		}
		start, startFound := periods[startSection]
		end, endFound := periods[endSection]
		if !startFound || !endFound {
			return nil, errors.New("period_mapping_missing")
		}
		// 周计划只需要时间占用信息；课程名称不是远端排程所必需的数据。
		events = append(events, hy3FixedEvent{Title: "课程", Weekday: weekday, Start: start.StartTime, End: end.EndTime})
	}
	return events, nil
}

func courseAppliesInWeek(course map[string]interface{}, week int) (bool, error) {
	values, exists := course["weeks"]
	if !exists || values == nil {
		return true, nil
	}
	weeks, ok := values.([]interface{})
	if !ok {
		return false, errors.New("course_weeks_invalid")
	}
	if len(weeks) == 0 {
		return true, nil
	}
	for _, rawWeek := range weeks {
		value, ok := jsonInt(rawWeek)
		if !ok || value < 1 || value > 30 {
			return false, errors.New("course_week_invalid")
		}
		if value == week {
			return true, nil
		}
	}
	return false, nil
}

func validateHy3FixedEvents(events []hy3FixedEvent) []string {
	byDay := make(map[int][]hy3FixedEvent, 7)
	for _, event := range events {
		if event.Weekday < 1 || event.Weekday > 7 || event.Title == "" || !validHy3Clock(event.Start) || !validHy3Clock(event.End) || hy3ClockMinutes(event.End) <= hy3ClockMinutes(event.Start) {
			return []string{"fixed_event_invalid"}
		}
		byDay[event.Weekday] = append(byDay[event.Weekday], event)
	}
	issues := make([]string, 0)
	for _, dayEvents := range byDay {
		sort.Slice(dayEvents, func(i, j int) bool { return hy3ClockMinutes(dayEvents[i].Start) < hy3ClockMinutes(dayEvents[j].Start) })
		for index := 1; index < len(dayEvents); index++ {
			if hy3ClockMinutes(dayEvents[index].Start) < hy3ClockMinutes(dayEvents[index-1].End) {
				issues = append(issues, "fixed_events_overlap")
			}
		}
	}
	return sortedHy3Issues(issues)
}

// sanitizeHy3WeekPlan 只保留与当前高层目标一致、通过本地硬约束复核的计划字段。
// 远端的统计、未知字段和建议不得直接透传给外层模型。
func sanitizeHy3WeekPlan(schedule map[string]interface{}, fixedEvents []hy3FixedEvent, constraints hy3PlanConstraints, goals []map[string]interface{}, findings map[string]interface{}) (map[string]interface{}, []string) {
	planRaw, ok := findings["plan"].([]interface{})
	if !ok || len(planRaw) > 500 {
		return nil, []string{"plan_missing"}
	}
	weekStart, err := time.Parse("2006-01-02", fmt.Sprint(schedule["week_start"]))
	if err != nil {
		return nil, []string{"week_start_invalid"}
	}
	expectedGoals, goalOrder, totalRequested, validGoals := hy3PlanGoalBudgets(goals)
	if !validGoals {
		return nil, []string{"goals_invalid"}
	}
	fixedByDay := make(map[int][]hy3FixedEvent, 7)
	for _, event := range fixedEvents {
		fixedByDay[event.Weekday] = append(fixedByDay[event.Weekday], event)
	}
	sleep := hy3SleepIntervals(constraints)
	byDay := make(map[int][]hy3PlanItem, 7)
	scheduledByGoal := make(map[string]int, len(expectedGoals))
	safePlan := make([]map[string]interface{}, 0, len(planRaw))
	issues := make([]string, 0)
	for _, rawItem := range planRaw {
		item, ok := rawItem.(map[string]interface{})
		if !ok || !hy3HasExactKeys(item, "goal", "priority", "weekday", "date", "start", "end", "minutes") {
			issues = append(issues, "plan_item_invalid")
			continue
		}
		goal, goalOK := item["goal"].(string)
		goal = strings.TrimSpace(goal)
		priority, priorityOK := item["priority"].(string)
		budget, knownGoal := expectedGoals[goal]
		if !goalOK || goal == "" || len([]rune(goal)) > 200 || !priorityOK || !knownGoal || priority != budget.Priority {
			issues = append(issues, "plan_goal_invalid")
			continue
		}
		weekday, weekdayOK := jsonInt(item["weekday"])
		start, startOK := item["start"].(string)
		end, endOK := item["end"].(string)
		minutes, minutesOK := jsonInt(item["minutes"])
		date, dateOK := item["date"].(string)
		if !weekdayOK || weekday < 1 || weekday > 7 || !startOK || !endOK || !minutesOK || !dateOK || !validHy3Clock(start) || !validHy3Clock(end) {
			issues = append(issues, "plan_item_invalid")
			continue
		}
		startMinute, endMinute := hy3ClockMinutes(start), hy3ClockMinutes(end)
		if endMinute <= startMinute || endMinute-startMinute != minutes || minutes < constraints.MinimumBlockMinutes {
			issues = append(issues, "plan_duration_invalid")
		}
		if date != weekStart.AddDate(0, 0, weekday-1).Format("2006-01-02") {
			issues = append(issues, "plan_date_invalid")
		}
		for _, event := range fixedByDay[weekday] {
			if hy3IntervalsOverlap(startMinute, endMinute, hy3ClockMinutes(event.Start), hy3ClockMinutes(event.End)) {
				issues = append(issues, "plan_conflicts_fixed_event")
			}
		}
		for _, interval := range sleep {
			if hy3IntervalsOverlap(startMinute, endMinute, interval.Start, interval.End) {
				issues = append(issues, "plan_conflicts_sleep")
			}
		}
		byDay[weekday] = append(byDay[weekday], hy3PlanItem{Goal: goal, Priority: priority, Start: startMinute, End: endMinute, Minutes: minutes})
		scheduledByGoal[goal] += minutes
		safePlan = append(safePlan, map[string]interface{}{
			"goal": goal, "priority": priority, "weekday": weekday, "date": date,
			"start": start, "end": end, "minutes": minutes,
		})
	}

	dailyAssigned := make(map[string]int, 7)
	totalScheduled := 0
	for weekday := 1; weekday <= 7; weekday++ {
		items := byDay[weekday]
		total := 0
		sort.Slice(items, func(i, j int) bool { return items[i].Start < items[j].Start })
		for index, item := range items {
			total += item.Minutes
			if index > 0 && hy3IntervalsOverlap(items[index-1].Start, items[index-1].End, item.Start, item.End) {
				issues = append(issues, "plan_items_overlap")
			}
		}
		if total > constraints.DailyMaxMinutes {
			issues = append(issues, "plan_exceeds_daily_max")
		}
		dailyAssigned[fmt.Sprint(weekday)] = total
		totalScheduled += total
	}

	unscheduled := make([]map[string]interface{}, 0, len(goalOrder))
	for _, goal := range goalOrder {
		budget := expectedGoals[goal]
		if scheduledByGoal[goal] > budget.RequestedMinutes {
			issues = append(issues, "plan_goal_exceeds_requested")
			continue
		}
		if remaining := budget.RequestedMinutes - scheduledByGoal[goal]; remaining > 0 {
			unscheduled = append(unscheduled, map[string]interface{}{"goal": goal, "minutes": remaining})
		}
	}
	if len(issues) > 0 {
		return nil, sortedHy3Issues(issues)
	}
	return map[string]interface{}{
		"plan":                    safePlan,
		"daily_assigned_minutes":  dailyAssigned,
		"total_requested_minutes": totalRequested,
		"total_scheduled_minutes": totalScheduled,
		"unscheduled":             unscheduled,
	}, nil
}

type hy3PlanGoalBudget struct {
	Priority         string
	RequestedMinutes int
}

func hy3PlanGoalBudgets(goals []map[string]interface{}) (map[string]hy3PlanGoalBudget, []string, int, bool) {
	budgets := make(map[string]hy3PlanGoalBudget, len(goals))
	order := make([]string, 0, len(goals))
	total := 0
	for _, rawGoal := range goals {
		name, nameOK := rawGoal["name"].(string)
		priority, priorityOK := rawGoal["priority"].(string)
		minutes, minutesOK := rawGoal["weekly_minutes"].(int)
		if !nameOK || !priorityOK || !minutesOK || name == "" || minutes < 1 || minutes > 10080 {
			return nil, nil, 0, false
		}
		if _, exists := budgets[name]; exists {
			return nil, nil, 0, false
		}
		budgets[name] = hy3PlanGoalBudget{Priority: priority, RequestedMinutes: minutes}
		order = append(order, name)
		total += minutes
	}
	return budgets, order, total, true
}

func hy3HasExactKeys(value map[string]interface{}, expected ...string) bool {
	if len(value) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, found := value[key]; !found {
			return false
		}
	}
	return true
}

type hy3PlanItem struct {
	Goal     string
	Priority string
	Start    int
	End      int
	Minutes  int
}

type hy3Interval struct {
	Start int
	End   int
}

func hy3SleepIntervals(constraints hy3PlanConstraints) []hy3Interval {
	start, end := hy3ClockMinutes(constraints.SleepStart), hy3ClockMinutes(constraints.SleepEnd)
	if start < end {
		return []hy3Interval{{Start: start, End: end}}
	}
	return []hy3Interval{{Start: 0, End: end}, {Start: start, End: 24 * 60}}
}

func hy3IntervalsOverlap(firstStart, firstEnd, secondStart, secondEnd int) bool {
	return firstStart < secondEnd && secondStart < firstEnd
}

func validHy3Clock(value string) bool {
	if len(value) != 5 {
		return false
	}
	_, err := time.Parse("15:04", value)
	return err == nil
}

func hy3ClockMinutes(value string) int {
	parsed, err := time.Parse("15:04", value)
	if err != nil {
		return -1
	}
	return parsed.Hour()*60 + parsed.Minute()
}

type hy3RemoteEnvelope struct {
	Result                map[string]interface{}
	DeterministicFindings map[string]interface{}
	Warnings              []string
}

func (decision *hy3DecisionMCP) callRemote(ctx context.Context, name string, arguments map[string]interface{}) (hy3RemoteEnvelope, map[string]interface{}) {
	if decision.remote == nil {
		return hy3RemoteEnvelope{}, hy3Unavailable(mcpclient.ErrorDisabled, "Hy3 决策服务未启用，请依据已取得的确定性数据回答。")
	}
	payload, err := decision.remote.CallTool(ctx, name, arguments)
	if err != nil {
		return hy3RemoteEnvelope{}, hy3Unavailable(mcpclient.ErrorCode(err), "Hy3 决策服务暂时不可用，请依据已取得的确定性数据回答。")
	}
	envelope, err := decodeHy3RemoteEnvelope(payload)
	if err != nil {
		return hy3RemoteEnvelope{}, hy3Unavailable(mcpclient.ErrorInvalidResult, "Hy3 决策服务返回格式无效，请依据已取得的确定性数据回答。")
	}
	if name == "explain_competition_candidates" {
		result, err := sanitizeHy3CandidateExplanationResult(arguments, envelope.Result)
		if err != nil {
			return hy3RemoteEnvelope{}, hy3Unavailable(
				mcpclient.ErrorInvalidResult,
				"Hy3 候选解释未通过本地 ID、顺序、来源或措辞校验，已丢弃该结果。",
			)
		}
		envelope.Result = result
		return envelope, nil
	}
	if name == "compare_selected_competitions" {
		result, err := sanitizeHy3SelectedComparisonResult(arguments, envelope.Result)
		if err != nil {
			return hy3RemoteEnvelope{}, hy3Unavailable(
				mcpclient.ErrorInvalidResult,
				"Hy3 比较结果未通过本地 ID、顺序、来源或措辞校验，已丢弃该结果。",
			)
		}
		envelope.Result = result
		return envelope, nil
	}
	result, err := sanitizeHy3NarrativeResult(name, envelope.Result)
	if err != nil {
		return hy3RemoteEnvelope{}, hy3Unavailable(mcpclient.ErrorInvalidResult, "Hy3 决策服务返回格式无效，请依据已取得的确定性数据回答。")
	}
	envelope.Result = result
	return envelope, nil
}

func sanitizeHy3CandidateExplanationResult(
	arguments map[string]interface{},
	input map[string]interface{},
) (map[string]interface{}, error) {
	candidates, ok := arguments["candidates"].([]map[string]interface{})
	if !ok || len(candidates) < 1 || len(candidates) > 20 {
		return nil, errors.New("candidate_arguments_invalid")
	}
	expected := make([]dto.CompetitionCandidateDTO, 0, len(candidates))
	for _, candidate := range candidates {
		competitionID, _ := candidate["competition_id"].(string)
		expected = append(expected, dto.CompetitionCandidateDTO{
			CompetitionPublicDTO: dto.CompetitionPublicDTO{CompetitionID: competitionID},
		})
	}
	encoded, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(encoded)))
	decoder.DisallowUnknownFields()
	var output Hy3CompetitionExplanation
	if err := decoder.Decode(&output); err != nil {
		return nil, err
	}
	if err := ValidateHy3CompetitionExplanation(expected, output); err != nil {
		return nil, err
	}
	sanitized, err := json.Marshal(output)
	if err != nil {
		return nil, err
	}
	var result map[string]interface{}
	if err := json.Unmarshal(sanitized, &result); err != nil {
		return nil, err
	}
	return result, nil
}

func decodeHy3RemoteEnvelope(payload json.RawMessage) (hy3RemoteEnvelope, error) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(payload, &raw) != nil {
		return hy3RemoteEnvelope{}, errors.New("envelope_invalid")
	}
	var status string
	if json.Unmarshal(raw["status"], &status) != nil || status != "ok" {
		return hy3RemoteEnvelope{}, errors.New("envelope_status_invalid")
	}
	result := make(map[string]interface{})
	findings := make(map[string]interface{})
	if json.Unmarshal(raw["result"], &result) != nil || result == nil || json.Unmarshal(raw["deterministic_findings"], &findings) != nil || findings == nil {
		return hy3RemoteEnvelope{}, errors.New("envelope_body_invalid")
	}
	warnings := make([]string, 0)
	if rawWarnings, exists := raw["warnings"]; exists {
		if json.Unmarshal(rawWarnings, &warnings) != nil || len(warnings) > 50 {
			return hy3RemoteEnvelope{}, errors.New("envelope_warnings_invalid")
		}
		for _, warning := range warnings {
			if len([]rune(warning)) > 500 {
				return hy3RemoteEnvelope{}, errors.New("envelope_warning_too_long")
			}
		}
	}
	return hy3RemoteEnvelope{Result: result, DeterministicFindings: findings, Warnings: warnings}, nil
}

func sanitizeHy3SelectedComparisonResult(
	arguments map[string]interface{},
	input map[string]interface{},
) (map[string]interface{}, error) {
	competitions, ok := arguments["competitions"].([]map[string]interface{})
	if !ok || len(competitions) < 2 || len(competitions) > 4 {
		return nil, errors.New("selected_competitions_invalid")
	}
	expectedIDs := make([]string, 0, len(competitions))
	for _, competition := range competitions {
		competitionID, ok := competition["competition_id"].(string)
		if !ok || strings.TrimSpace(competitionID) == "" {
			return nil, errors.New("selected_competition_id_invalid")
		}
		expectedIDs = append(expectedIDs, competitionID)
	}
	encoded, err := json.Marshal(input)
	if err != nil {
		return nil, err
	}
	var output Hy3SelectedCompetitionComparison
	if err := decodeToolArguments(encoded, &output); err != nil {
		return nil, err
	}
	if err := ValidateHy3SelectedCompetitionComparison(expectedIDs, output); err != nil {
		return nil, err
	}
	clean, err := json.Marshal(output)
	if err != nil {
		return nil, err
	}
	var result map[string]interface{}
	if err := json.Unmarshal(clean, &result); err != nil {
		return nil, err
	}
	return result, nil
}

type hy3NarrativeContract struct {
	TextFields []string
	ListFields []string
}

var hy3NarrativeContracts = map[string]hy3NarrativeContract{
	"compare_competitions": {
		TextFields: []string{"recommendation", "rationale"},
		ListFields: []string{"considerations"},
	},
	"analyze_academic_snapshot": {
		TextFields: []string{"risk_summary"},
		ListFields: []string{"priority_actions", "items_to_confirm"},
	},
	"plan_student_week": {
		TextFields: []string{"weekly_strategy"},
		ListFields: []string{"priority_order", "notes"},
	},
}

// sanitizeHy3NarrativeResult 校验 MCP 叙事输出的精确字段集合，防止未约定内容透传。
func sanitizeHy3NarrativeResult(toolName string, input map[string]interface{}) (map[string]interface{}, error) {
	contract, found := hy3NarrativeContracts[toolName]
	if !found || len(input) != len(contract.TextFields)+len(contract.ListFields) {
		return nil, errors.New("narrative_contract_invalid")
	}
	result := make(map[string]interface{}, len(input))
	for _, field := range contract.TextFields {
		value, ok := input[field].(string)
		value = strings.TrimSpace(value)
		if !ok || value == "" || len([]rune(value)) > 4000 {
			return nil, errors.New("narrative_text_invalid")
		}
		result[field] = value
	}
	for _, field := range contract.ListFields {
		values, ok := input[field].([]interface{})
		if !ok || len(values) > 20 {
			return nil, errors.New("narrative_list_invalid")
		}
		items := make([]string, 0, len(values))
		for _, rawValue := range values {
			value, valueOK := rawValue.(string)
			value = strings.TrimSpace(value)
			if !valueOK || value == "" || len([]rune(value)) > 4000 {
				return nil, errors.New("narrative_list_item_invalid")
			}
			items = append(items, value)
		}
		result[field] = items
	}
	return result, nil
}

// sanitizeHy3AcademicFindings 仅接受独立 MCP 已公开的确定性学业字段。
// 课程名称来自 Go 已脱敏的快照，因此仍按长度和类型重新限制。
func sanitizeHy3AcademicFindings(input map[string]interface{}) (map[string]interface{}, error) {
	if !hy3HasExactKeys(input,
		"failed_course_count", "failed_required_credits", "earned_credits", "credit_gap", "erke_gap",
		"unknown_grade_course_count", "missing_credit_course_count", "data_completeness_percent", "failed_courses",
	) {
		return nil, errors.New("academic_findings_contract_invalid")
	}
	failedCourseCount, failedCourseCountOK := hy3RemoteCount(input["failed_course_count"], 500)
	failedRequiredCredits, failedRequiredCreditsOK := hy3RemoteNumber(input["failed_required_credits"], 1000)
	earnedCredits, earnedCreditsOK := hy3RemoteNumber(input["earned_credits"], 1000)
	creditGap, creditGapOK := hy3RemoteNumber(input["credit_gap"], 1000)
	erkeGap, erkeGapOK := hy3RemoteNumber(input["erke_gap"], 1000)
	unknownGradeCount, unknownGradeCountOK := hy3RemoteCount(input["unknown_grade_course_count"], 500)
	missingCreditCount, missingCreditCountOK := hy3RemoteCount(input["missing_credit_course_count"], 500)
	completeness, completenessOK := hy3RemoteNumber(input["data_completeness_percent"], 100)
	failedCoursesRaw, failedCoursesOK := input["failed_courses"].([]interface{})
	if !failedCourseCountOK || !failedRequiredCreditsOK || !earnedCreditsOK || !creditGapOK || !erkeGapOK ||
		!unknownGradeCountOK || !missingCreditCountOK || !completenessOK || !failedCoursesOK || len(failedCoursesRaw) > 500 {
		return nil, errors.New("academic_findings_invalid")
	}
	failedCourses := make([]string, 0, len(failedCoursesRaw))
	for _, rawCourse := range failedCoursesRaw {
		course, ok := rawCourse.(string)
		course = strings.TrimSpace(course)
		if !ok || course == "" || len([]rune(course)) > 200 {
			return nil, errors.New("academic_failed_course_invalid")
		}
		failedCourses = append(failedCourses, course)
	}
	if failedCourseCount != len(failedCourses) {
		return nil, errors.New("academic_failed_course_count_invalid")
	}
	return map[string]interface{}{
		"failed_course_count":         failedCourseCount,
		"failed_required_credits":     failedRequiredCredits,
		"earned_credits":              earnedCredits,
		"credit_gap":                  creditGap,
		"erke_gap":                    erkeGap,
		"unknown_grade_course_count":  unknownGradeCount,
		"missing_credit_course_count": missingCreditCount,
		"data_completeness_percent":   completeness,
		"failed_courses":              failedCourses,
	}, nil
}

func hy3RemoteNumber(value interface{}, maximum float64) (float64, bool) {
	number, ok := value.(float64)
	return number, ok && number >= 0 && number <= maximum
}

func hy3RemoteCount(value interface{}, maximum int) (int, bool) {
	number, ok := hy3RemoteNumber(value, float64(maximum))
	if !ok || number != float64(int(number)) {
		return 0, false
	}
	return int(number), true
}

// reserveExternalCall 在数据库审计记录已创建后检查同一 Run 的调用次数。
// 当前配置固定为每个 Run 一次外部调用，避免一个模型回合反复请求 Hy3。
func (decision *hy3DecisionMCP) reserveExternalCall(ctx context.Context) map[string]interface{} {
	call, hasCall := currentToolCallContext(ctx)
	if !hasCall || decision.db == nil {
		return nil
	}
	var count int64
	err := decision.db.WithContext(ctx).Model(&models.AIToolCall{}).
		Where("run_id = ? AND tool_name IN ? AND call_id <> ? AND status IN ?", call.RunID, hy3DecisionToolNames, call.CallID, []string{"pending", "running", "waiting", "completed"}).
		Count(&count).Error
	if err != nil {
		return hy3Unavailable(mcpclient.ErrorUnavailable, "无法确认 Hy3 决策调用额度，请依据已取得的确定性数据回答。")
	}
	if count >= 1 {
		return hy3Unavailable(mcpclient.ErrorConstraint, "每个 AI 对话最多调用一次 Hy3 决策服务，请依据已取得的结果继续回答。")
	}
	return nil
}

func hy3Unavailable(code, warning string) map[string]interface{} {
	return map[string]interface{}{"status": "unavailable", "error_code": code, "warnings": []string{warning}}
}

func hy3PersonalUnavailable(warning string) map[string]interface{} {
	return map[string]interface{}{"status": "unavailable", "error_code": "personal_context_unavailable", "warnings": []string{warning}}
}

func hy3PersonalUnavailableFromResult(result academic.ContextResult) map[string]interface{} {
	warnings := append([]string(nil), result.Warnings...)
	if len(warnings) == 0 {
		warnings = []string{"没有可用的已授权个人数据，无法执行 Hy3 决策分析。"}
	}
	return map[string]interface{}{"status": "unavailable", "error_code": "personal_context_unavailable", "warnings": warnings}
}

func firstHy3String(value map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		candidate, ok := value[key]
		if !ok {
			continue
		}
		text, ok := candidate.(string)
		if ok && strings.TrimSpace(text) != "" {
			return strings.TrimSpace(text)
		}
	}
	return ""
}

func firstHy3Number(value map[string]interface{}, keys ...string) (float64, bool) {
	for _, key := range keys {
		if number, ok := jsonNumber(value[key]); ok {
			return number, true
		}
	}
	return 0, false
}

func firstHy3Int(value map[string]interface{}, keys ...string) (int, bool) {
	for _, key := range keys {
		if number, ok := jsonInt(value[key]); ok {
			return number, true
		}
	}
	return 0, false
}

func nullableHy3Text(value string, maximum int) interface{} {
	value = truncateHy3Text(strings.TrimSpace(value), maximum)
	if value == "" {
		return nil
	}
	return value
}

func truncateHy3Text(value string, maximum int) string {
	value = strings.TrimSpace(value)
	if maximum <= 0 || len([]rune(value)) <= maximum {
		return value
	}
	return string([]rune(value)[:maximum])
}

func sortedHy3Issues(issues []string) []string {
	if len(issues) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(issues))
	for _, issue := range issues {
		seen[issue] = struct{}{}
	}
	result := make([]string, 0, len(seen))
	for issue := range seen {
		result = append(result, issue)
	}
	sort.Strings(result)
	return result
}
