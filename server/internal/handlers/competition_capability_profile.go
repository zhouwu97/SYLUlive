package handlers

import (
	"errors"
	"net/http"
	"sort"
	"strings"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type competitionCapabilityCount struct {
	Skill             string `json:"skill,omitempty"`
	Role              string `json:"role,omitempty"`
	VerifiedCount     int    `json:"verified_count"`
	SelfReportedCount int    `json:"self_reported_count"`
}

type competitionCapabilityProfileResponse struct {
	PreferenceConfigured   bool                         `json:"preference_configured"`
	Goals                  []string                     `json:"goals"`
	VerifiedAwardCount     int                          `json:"verified_award_count"`
	SelfReportedAwardCount int                          `json:"self_reported_award_count"`
	SkillSummary           []competitionCapabilityCount `json:"skill_summary"`
	RoleSummary            []competitionCapabilityCount `json:"role_summary"`
	DirectionTags          []string                     `json:"direction_tags"`
	PreferredRoles         []string                     `json:"preferred_roles"`
	WeeklyHours            int                          `json:"weekly_hours"`
	AcceptLongTermTraining bool                         `json:"accept_long_term_training"`
}

func emptyCompetitionCapabilityProfile() competitionCapabilityProfileResponse {
	return competitionCapabilityProfileResponse{
		Goals:          []string{},
		SkillSummary:   []competitionCapabilityCount{},
		RoleSummary:    []competitionCapabilityCount{},
		DirectionTags:  []string{},
		PreferredRoles: []string{},
	}
}

// GetCompetitionCapabilityProfile 返回当前用户的结构化竞赛画像，不推导能力等级或推荐分。
func (h *CompetitionHandler) GetCompetitionCapabilityProfile(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	profile, err := h.loadCompetitionCapabilityProfile(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛能力画像失败"})
		return
	}
	c.JSON(http.StatusOK, profile)
}

func (h *CompetitionHandler) loadCompetitionCapabilityProfile(userID uint) (competitionCapabilityProfileResponse, error) {
	return h.loadCompetitionCapabilityProfileWithDB(h.db, userID)
}

func (h *CompetitionHandler) loadCompetitionCapabilityProfileWithDB(db *gorm.DB, userID uint) (competitionCapabilityProfileResponse, error) {
	profile := emptyCompetitionCapabilityProfile()

	var preference models.UserCompetitionPreference
	if err := db.Where("user_id = ?", userID).First(&preference).Error; err == nil {
		profile.PreferenceConfigured = true
		profile.Goals = decodeStringArray(preference.Goals)
		profile.DirectionTags = decodeStringArray(preference.DirectionTags)
		profile.PreferredRoles = decodeStringArray(preference.PreferredRoles)
		profile.WeeklyHours = preference.WeeklyHours
		profile.AcceptLongTermTraining = preference.AcceptLongTermTraining
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return profile, err
	}

	var awards []models.UserCompetitionAward
	if err := db.
		Where("user_id = ? AND verification_status IN ?", userID, []string{"verified", "self_reported"}).
		Order("id ASC").
		Find(&awards).Error; err != nil {
		return profile, err
	}

	skills := make(map[string]*competitionCapabilityCount)
	roles := make(map[string]*competitionCapabilityCount)
	for _, award := range awards {
		verified := award.VerificationStatus == "verified"
		if verified {
			profile.VerifiedAwardCount++
		} else {
			profile.SelfReportedAwardCount++
		}

		seenSkills := make(map[string]struct{})
		for _, skill := range decodeStringArray(award.SkillTags) {
			skill = strings.TrimSpace(skill)
			if skill == "" {
				continue
			}
			if _, exists := seenSkills[skill]; exists {
				continue
			}
			seenSkills[skill] = struct{}{}
			entry := skills[skill]
			if entry == nil {
				entry = &competitionCapabilityCount{Skill: skill}
				skills[skill] = entry
			}
			incrementCompetitionCapabilityCount(entry, verified)
		}

		role := strings.TrimSpace(award.Role)
		if role != "" {
			entry := roles[role]
			if entry == nil {
				entry = &competitionCapabilityCount{Role: role}
				roles[role] = entry
			}
			incrementCompetitionCapabilityCount(entry, verified)
		}
	}

	profile.SkillSummary = sortedCompetitionCapabilityCounts(skills)
	profile.RoleSummary = sortedCompetitionCapabilityCounts(roles)
	return profile, nil
}

func incrementCompetitionCapabilityCount(entry *competitionCapabilityCount, verified bool) {
	if verified {
		entry.VerifiedCount++
		return
	}
	entry.SelfReportedCount++
}

func sortedCompetitionCapabilityCounts(values map[string]*competitionCapabilityCount) []competitionCapabilityCount {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]competitionCapabilityCount, 0, len(keys))
	for _, key := range keys {
		result = append(result, *values[key])
	}
	return result
}
