package handlers

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/services"
)

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
	// 兼容层明确不写 personalized_score 和 recommendation_tier。
	delete(result, "personalized_score")
	delete(result, "recommendation_tier")
	return result
}
