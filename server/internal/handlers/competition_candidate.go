package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/services"
)

// CompetitionCandidateExplanationTool 是处理器使用的最小 Hy3 工具边界。
type CompetitionCandidateExplanationTool interface {
	Execute(context.Context, uint, json.RawMessage) (interface{}, error)
}

// SetCompetitionCandidateExplanationTool 在路由启动前注入已经过远端契约校验的候选解释工具。
func (h *CompetitionHandler) SetCompetitionCandidateExplanationTool(
	tool CompetitionCandidateExplanationTool,
) {
	h.candidateExplanationTool = tool
}

// ListCompetitionCandidates 返回按目录权限构建的确定性候选分组。
func (h *CompetitionHandler) ListCompetitionCandidates(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	result, err := services.NewCompetitionCandidateEngine(h.db).BuildCandidates(
		c.Request.Context(), userID, candidateFilterFromRequest(c),
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛候选失败"})
		return
	}
	c.JSON(http.StatusOK, result)
}

type competitionCandidateExplanationRequest struct {
	CompetitionIDs []uint `json:"competition_ids"`
	Question       string `json:"question"`
}

// ExplainCompetitionCandidates 重新校验候选集合后调用 Hy3，只返回附加解释。
func (h *CompetitionHandler) ExplainCompetitionCandidates(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	if h.candidateExplanationTool == nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"error": "竞赛候选解释暂不可用"})
		return
	}
	var request competitionCandidateExplanationRequest
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 16<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "候选解释请求格式无效"})
		return
	}
	if len(request.CompetitionIDs) < 1 || len(request.CompetitionIDs) > 20 ||
		!uniqueCompetitionEventIDs(request.CompetitionIDs) ||
		len([]rune(strings.TrimSpace(request.Question))) > 500 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "候选解释请求参数无效"})
		return
	}
	arguments, err := json.Marshal(gin.H{
		"event_ids": request.CompetitionIDs,
		"question":  strings.TrimSpace(request.Question),
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "构造候选解释请求失败"})
		return
	}
	result, err := h.candidateExplanationTool.Execute(
		c.Request.Context(), userID, arguments,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成竞赛候选解释失败"})
		return
	}
	c.JSON(http.StatusOK, result)
}

func uniqueCompetitionEventIDs(ids []uint) bool {
	seen := make(map[uint]struct{}, len(ids))
	for _, id := range ids {
		if id == 0 {
			return false
		}
		if _, exists := seen[id]; exists {
			return false
		}
		seen[id] = struct{}{}
	}
	return true
}

func (h *CompetitionHandler) listLegacyFitEvents(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	result, err := services.NewCompetitionCandidateEngine(h.db).BuildCandidates(
		c.Request.Context(), userID, candidateFilterFromRequest(c),
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛候选失败"})
		return
	}
	items := make([]map[string]interface{}, 0)
	for _, group := range result.Groups {
		for _, candidate := range group.Items {
			items = append(items, legacyCandidateMap(candidate))
		}
	}
	c.JSON(http.StatusOK, gin.H{
		"profile_ready": result.ProfileReady, "preference_configured": result.PreferenceConfigured,
		"items": items, "total": result.Total, "page": result.Page, "page_size": result.PageSize,
		"deprecated": true, "catalog": result.Catalog,
	})
}

func candidateFilterFromRequest(c *gin.Context) services.CandidateFilter {
	page, _ := strconv.Atoi(c.DefaultQuery("page", "1"))
	pageSize, _ := strconv.Atoi(c.DefaultQuery("page_size", "20"))
	return services.CandidateFilter{
		Page: page, PageSize: pageSize, Keyword: c.Query("keyword"),
		CategorySlug:            c.Query("category_slug"),
		SchoolRecognitionStatus: c.Query("school_recognition_status"),
		DateStatus:              c.Query("date_status"),
	}
}

func legacyCandidateMap(candidate dto.CompetitionCandidateDTO) map[string]interface{} {
	encoded, _ := json.Marshal(candidate)
	var result map[string]interface{}
	_ = json.Unmarshal(encoded, &result)
	result["fit_level"] = candidate.GroupKey
	result["fit_reasons"] = []string{candidate.CoreReason}
	result["gates"] = candidate.Gates
	// 兼容层明确不写 personalized_score 和 recommendation_tier。
	delete(result, "personalized_score")
	delete(result, "recommendation_tier")
	return result
}
