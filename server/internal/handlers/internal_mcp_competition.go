package handlers

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/ai"
	"shenliyuan/internal/competitionscope"
	"shenliyuan/internal/models"
)

// InternalMCPGrantMiddleware 只允许持有固定服务 Grant 的纯 MCP 读取公开事实。
func InternalMCPGrantMiddleware(expected string) gin.HandlerFunc {
	expected = strings.TrimSpace(expected)
	return func(c *gin.Context) {
		if expected == "" {
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{"error": "MCP 内部事实网关未启用"})
			return
		}
		provided := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
		if len(provided) != len(expected) ||
			subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "MCP Grant 无效"})
			return
		}
		c.Next()
	}
}

// InternalMCPScopedGrantMiddleware 校验一次 Run 专属的 opaque Grant。
// Grant 中的 subject 只写入 Go request Context，绝不写回 JSON 或传给模型。
func InternalMCPScopedGrantMiddleware(manager *ai.ScopedGrantManager) gin.HandlerFunc {
	return func(c *gin.Context) {
		if manager == nil {
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{"error": "MCP scoped grant 未启用"})
			return
		}
		provided := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
		capability := internalMCPCapabilityForPath(c.Request.URL.Path)
		grant, err := manager.VerifyContext(c.Request.Context(), provided, capability)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "MCP Grant 无效"})
			return
		}
		c.Request = c.Request.WithContext(ai.WithScopedGrant(c.Request.Context(), grant))
		c.Next()
	}
}

// InternalMCPGrantOrScopedGrantMiddleware 兼容旧的公开事实服务 Grant，同时允许新 Runtime 使用 Run Scoped Grant。
// 迁移期间两种 token 可以并存；个人数据端点必须由新 Grant 的 scope 再次校验。
func InternalMCPGrantOrScopedGrantMiddleware(expected string, manager *ai.ScopedGrantManager) gin.HandlerFunc {
	return func(c *gin.Context) {
		provided := strings.TrimSpace(strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer "))
		if expected != "" && len(provided) == len(expected) && subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1 {
			c.Next()
			return
		}
		if manager == nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "MCP Grant 无效"})
			return
		}
		capability := internalMCPCapabilityForPath(c.Request.URL.Path)
		grant, err := manager.VerifyContext(c.Request.Context(), provided, capability)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "MCP Grant 无效"})
			return
		}
		c.Request = c.Request.WithContext(ai.WithScopedGrant(c.Request.Context(), grant))
		c.Next()
	}
}

func internalMCPCapabilityForPath(path string) string {
	path = strings.TrimRight(path, "/")
	switch path {
	case "/internal/mcp/system/status":
		return "system.status"
	case "/internal/mcp/policy/search":
		return "policy.search"
	case "/internal/mcp/policy/sources":
		return "policy.sources"
	case "/internal/mcp/competition/search":
		return "competition.search"
	case "/internal/mcp/competition/details":
		return "competition.details"
	case "/internal/mcp/competition/candidate-context":
		return "competition.governed_context"
	case "/internal/mcp/competition/compare":
		return "competition.compare"
	case "/internal/mcp/competition/verify-records":
		return "competition.verify"
	case "/internal/mcp/academic/summary":
		return "academic.summary"
	case "/internal/mcp/schedule/free-windows":
		return "schedule.free_windows"
	case "/internal/mcp/schedule/validate-plan":
		return "schedule.validate_plan"
	default:
		return ""
	}
}

type internalCompetitionIDsInput struct {
	CompetitionIDs []string `json:"competition_ids"`
}

type internalCompetitionSearchInput struct {
	Query      string   `json:"query"`
	Categories []string `json:"categories"`
	Limit      int      `json:"limit"`
}

type internalCompetitionCompareInput struct {
	CompetitionIDs       []string `json:"competition_ids"`
	AvailableWeeklyHours *int     `json:"available_weekly_hours"`
}

type internalCompetitionVerifyRecord struct {
	CompetitionID string `json:"competition_id"`
	RecordHash    string `json:"record_hash"`
}

type internalCompetitionVerifyInput struct {
	Records []internalCompetitionVerifyRecord `json:"records"`
}

func (h *CompetitionHandler) InternalMCPCompetitionSearch(c *gin.Context) {
	var input internalCompetitionSearchInput
	if !decodeInternalMCPJSON(c, &input) {
		return
	}
	if input.Limit < 1 || input.Limit > 20 {
		input.Limit = 10
	}
	query := h.internalPublishedCompetitionQuery()
	if value := strings.TrimSpace(input.Query); value != "" {
		pattern := "%" + strings.ToLower(value) + "%"
		query = query.Where("LOWER(competition_events.title) LIKE ? OR LOWER(competition_events.summary) LIKE ?", pattern, pattern)
	}
	if len(input.Categories) > 0 {
		query = query.Joins("JOIN competition_categories ON competition_categories.id = competition_events.primary_category_id").
			Where("competition_categories.name IN ? OR competition_categories.slug IN ?", input.Categories, input.Categories)
	}
	var events []models.CompetitionEvent
	if err := query.Order("catalog_order ASC, competition_id ASC").Limit(input.Limit).Find(&events).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取赛事事实失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "competitions": internalCompetitionFacts(events)})
}

func (h *CompetitionHandler) InternalMCPCompetitionDetails(c *gin.Context) {
	var input internalCompetitionIDsInput
	if !decodeInternalMCPJSON(c, &input) || !validateInternalCompetitionIDs(c, input.CompetitionIDs, 1, 20) {
		return
	}
	events, missing, err := h.loadInternalCompetitionEvents(input.CompetitionIDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取赛事事实失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"status": "ok", "competitions": internalCompetitionFacts(events),
		"missing_competition_ids": missing,
	})
}

func (h *CompetitionHandler) InternalMCPCompetitionCompare(c *gin.Context) {
	var input internalCompetitionCompareInput
	if !decodeInternalMCPJSON(c, &input) || !validateInternalCompetitionIDs(c, input.CompetitionIDs, 2, 5) {
		return
	}
	events, missing, err := h.loadInternalCompetitionEvents(input.CompetitionIDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取赛事事实失败"})
		return
	}
	if len(missing) > 0 {
		c.JSON(http.StatusUnprocessableEntity, gin.H{"error": "请求包含不存在或未公开的赛事"})
		return
	}
	facts := internalCompetitionFacts(events)
	for index := range facts {
		required := facts[index]["weekly_hours"].(int)
		timeMatch := false
		if input.AvailableWeeklyHours != nil {
			timeMatch = *input.AvailableWeeklyHours >= required
		}
		facts[index]["profile_match"] = gin.H{"major": false, "grade": nil, "time": timeMatch}
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "competitions": facts})
}

func (h *CompetitionHandler) InternalMCPCompetitionCandidateContext(c *gin.Context) {
	var input internalCompetitionIDsInput
	if !decodeInternalMCPJSON(c, &input) || !validateInternalCompetitionIDs(c, input.CompetitionIDs, 1, 20) {
		return
	}
	events, missing, err := h.loadInternalCompetitionEvents(input.CompetitionIDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取候选事实失败"})
		return
	}
	items := make([]gin.H, 0, len(events))
	for _, event := range events {
		items = append(items, gin.H{
			"competition_id": event.CompetitionID, "record_hash": event.RecordHash,
			"dataset_version": event.DatasetVersion,
			"facts": gin.H{
				"title": event.Title, "competition_level": event.CompetitionLevel,
				"school_recognition_status": event.SchoolRecognitionStatus,
				"school_recognition_grade":  event.SchoolRecognitionGrade,
				"competition_rating":        effectiveCompetitionRating(event),
				"participation_type":        event.ParticipationType,
				"team_size_min":             event.TeamSizeMin, "team_size_max": event.TeamSizeMax,
				"registration_time_text": event.RegistrationTimeText,
				"event_time_text":        event.EventTimeText, "time_status": event.TimeStatus,
				"manual_rating_reason_public": event.ManualRatingReasonPublic,
				"major_fit_summary_public":    event.MajorFitSummaryPublic,
				"evidence_summary_public":     event.EvidenceSummaryPublic,
				"evidence_subgrade":           event.EvidenceSubgrade,
			},
			"match_dimensions": gin.H{
				"eligibility": "unknown", "major": "unknown", "college": "unknown",
				"grade": "unknown", "goal": "unknown", "direction": "unknown",
				"skill": "unknown", "role": "unknown", "time": "unknown", "training": "unknown",
			},
			"risk_tags": decodeStringArray(event.RiskTags),
			"gates": gin.H{
				"candidate_pool_allowed":          event.CandidatePoolAllowed,
				"personalized_ranking_allowed":    event.PersonalizedRankingAllowed,
				"strong_recommendation_eligible":  event.StrongRecommendationEligible,
				"recommendation_permission_level": event.RecommendationPermissionLevel,
				"ai_mode":                         event.AIMode,
			},
		})
	}
	c.JSON(http.StatusOK, gin.H{
		"status": "ok", "candidates": items, "missing_competition_ids": missing,
	})
}

func (h *CompetitionHandler) InternalMCPCompetitionVerifyRecords(c *gin.Context) {
	var input internalCompetitionVerifyInput
	if !decodeInternalMCPJSON(c, &input) {
		return
	}
	if len(input.Records) < 1 || len(input.Records) > 50 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "records 数量必须在 1 到 50 之间"})
		return
	}
	results := make([]gin.H, 0, len(input.Records))
	for _, record := range input.Records {
		var event models.CompetitionEvent
		err := h.internalPublishedCompetitionQuery().
			Where("competition_events.competition_id = ?", strings.TrimSpace(record.CompetitionID)).First(&event).Error
		valid := err == nil && event.Status == "published" && event.SearchDisplayAllowed &&
			event.CandidatePoolAllowed && event.RecordHash == strings.TrimSpace(record.RecordHash)
		reason := ""
		switch {
		case errors.Is(err, gorm.ErrRecordNotFound):
			reason = "not_found"
		case err != nil:
			c.JSON(http.StatusInternalServerError, gin.H{"error": "复核赛事记录失败"})
			return
		case event.Status != "published":
			reason = "not_published"
		case !event.CandidatePoolAllowed:
			reason = "candidate_pool_closed"
		case event.RecordHash != strings.TrimSpace(record.RecordHash):
			reason = "record_hash_changed"
		}
		results = append(results, gin.H{
			"competition_id": record.CompetitionID, "record_hash": event.RecordHash,
			"valid": valid, "reason": reason, "ai_mode": event.AIMode,
		})
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "records": results})
}

func (h *CompetitionHandler) internalPublishedCompetitionQuery() *gorm.DB {
	query := h.db.Model(&models.CompetitionEvent{}).Preload("PrimaryCategory")
	scope, err := competitionscope.Resolve(context.Background(), h.db)
	if err != nil {
		query.AddError(err)
		return query
	}
	return scope.ApplyMCPFact(query)
}

func (h *CompetitionHandler) loadInternalCompetitionEvents(
	ids []string,
) ([]models.CompetitionEvent, []string, error) {
	var events []models.CompetitionEvent
	if err := h.internalPublishedCompetitionQuery().Where("competition_id IN ?", ids).Find(&events).Error; err != nil {
		return nil, nil, err
	}
	byID := make(map[string]models.CompetitionEvent, len(events))
	for _, event := range events {
		byID[event.CompetitionID] = event
	}
	ordered := make([]models.CompetitionEvent, 0, len(ids))
	missing := make([]string, 0)
	for _, id := range ids {
		if event, exists := byID[id]; exists {
			ordered = append(ordered, event)
		} else {
			missing = append(missing, id)
		}
	}
	return ordered, missing, nil
}

func internalCompetitionFacts(events []models.CompetitionEvent) []gin.H {
	result := make([]gin.H, 0, len(events))
	for _, event := range events {
		categories := []string{}
		if event.PrimaryCategory != nil {
			categories = append(categories, event.PrimaryCategory.Name)
		}
		weeklyHours := 7
		for _, risk := range decodeStringArray(event.RiskTags) {
			if risk == "long_term_training" || risk == "high_weekly_hours" {
				weeklyHours = 14
			}
		}
		evidence := "pending"
		if event.IsVerified {
			evidence = "official"
		}
		result = append(result, gin.H{
			"competition_id": event.CompetitionID, "name": event.Title,
			"categories": categories, "school_recognition": event.SchoolRecognitionGrade,
			"manual_rating": effectiveCompetitionRating(event), "eligible": nil,
			"major_tags":        decodeStringArray(event.EligibleMajors),
			"grade_eligibility": decodeStringArray(event.EligibleEntryYears),
			"weekly_hours":      weeklyHours, "evidence_quality": evidence,
			"source_id": "competition_catalog:" + event.CompetitionID,
		})
	}
	return result
}

func decodeInternalMCPJSON(c *gin.Context, destination interface{}) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 1<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "MCP 请求格式无效"})
		return false
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "MCP 请求只能包含一个 JSON 对象"})
		return false
	}
	return true
}

func validateInternalCompetitionIDs(c *gin.Context, ids []string, minimum, maximum int) bool {
	if len(ids) < minimum || len(ids) > maximum {
		c.JSON(http.StatusBadRequest, gin.H{"error": "competition_ids 数量无效"})
		return false
	}
	seen := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "competition_id 不能为空"})
			return false
		}
		if _, exists := seen[id]; exists {
			c.JSON(http.StatusBadRequest, gin.H{"error": "competition_id 不能重复"})
			return false
		}
		seen[id] = struct{}{}
	}
	return true
}
