package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

var competitionPreferenceGoals = map[string]struct{}{
	"resume": {}, "ability": {}, "exploration": {}, "postgraduate": {}, "graduation_gap": {},
}

var competitionPreferenceRoles = map[string]struct{}{
	"developer": {}, "modeler": {}, "hardware": {}, "designer": {},
	"writer": {}, "presenter": {}, "organizer": {}, "any": {},
}

var competitionExperienceLevels = map[string]struct{}{
	"beginner": {}, "participated": {}, "awarded": {}, "experienced": {},
}

type competitionPreferenceInput struct {
	Goals                  []string `json:"goals"`
	DirectionTags          []string `json:"direction_tags"`
	SkillTags              []string `json:"skill_tags"`
	PreferredRoles         []string `json:"preferred_roles"`
	WeeklyHours            int      `json:"weekly_hours"`
	AcceptLongTermTraining bool     `json:"accept_long_term_training"`
	CareerDirection        string   `json:"career_direction"`
	ExperienceLevel        string   `json:"experience_level"`
}

type competitionPreferenceResponse struct {
	Configured             bool     `json:"configured"`
	Goals                  []string `json:"goals"`
	DirectionTags          []string `json:"direction_tags"`
	SkillTags              []string `json:"skill_tags"`
	PreferredRoles         []string `json:"preferred_roles"`
	WeeklyHours            int      `json:"weekly_hours"`
	AcceptLongTermTraining bool     `json:"accept_long_term_training"`
	CareerDirection        string   `json:"career_direction"`
	ExperienceLevel        string   `json:"experience_level"`
}

func defaultCompetitionPreferenceResponse() competitionPreferenceResponse {
	return competitionPreferenceResponse{
		Goals: []string{}, DirectionTags: []string{}, SkillTags: []string{}, PreferredRoles: []string{},
		ExperienceLevel: "beginner",
	}
}

func competitionPreferenceResponseFromModel(preference models.UserCompetitionPreference) competitionPreferenceResponse {
	return competitionPreferenceResponse{
		Configured:             true,
		Goals:                  decodeStringArray(preference.Goals),
		DirectionTags:          decodeStringArray(preference.DirectionTags),
		SkillTags:              decodeStringArray(preference.SkillTags),
		PreferredRoles:         decodeStringArray(preference.PreferredRoles),
		WeeklyHours:            preference.WeeklyHours,
		AcceptLongTermTraining: preference.AcceptLongTermTraining,
		CareerDirection:        preference.CareerDirection,
		ExperienceLevel:        preference.ExperienceLevel,
	}
}

// GetCompetitionPreference 返回当前用户偏好；未配置时返回可直接编辑的默认结构。
func (h *CompetitionHandler) GetCompetitionPreference(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var preference models.UserCompetitionPreference
	if err := h.db.Where("user_id = ?", userID).First(&preference).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusOK, defaultCompetitionPreferenceResponse())
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛目标失败"})
		return
	}
	c.JSON(http.StatusOK, competitionPreferenceResponseFromModel(preference))
}

// PutCompetitionPreference 整体覆盖当前用户偏好，避免数组局部更新产生歧义。
func (h *CompetitionHandler) PutCompetitionPreference(c *gin.Context) {
	userID, ok := currentUserID(c)
	if !ok {
		return
	}
	var input competitionPreferenceInput
	decoder := json.NewDecoder(c.Request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "参数错误或包含不支持的字段"})
		return
	}
	if err := ensureJSONBodyEnded(decoder); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求只能包含一个 JSON 对象"})
		return
	}
	normalized, err := normalizeCompetitionPreferenceInput(input)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	preference := models.UserCompetitionPreference{
		UserID: userID,
		Goals:  jsonArray(normalized.Goals), DirectionTags: jsonArray(normalized.DirectionTags),
		SkillTags: jsonArray(normalized.SkillTags), PreferredRoles: jsonArray(normalized.PreferredRoles),
		WeeklyHours: normalized.WeeklyHours, AcceptLongTermTraining: normalized.AcceptLongTermTraining,
		CareerDirection: normalized.CareerDirection, ExperienceLevel: normalized.ExperienceLevel,
	}
	updates := map[string]interface{}{
		"goals": preference.Goals, "direction_tags": preference.DirectionTags,
		"skill_tags": preference.SkillTags, "preferred_roles": preference.PreferredRoles,
		"weekly_hours": preference.WeeklyHours, "accept_long_term_training": preference.AcceptLongTermTraining,
		"career_direction": preference.CareerDirection, "experience_level": preference.ExperienceLevel,
	}
	if err := h.db.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "user_id"}}, DoUpdates: clause.Assignments(updates),
	}).Create(&preference).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存竞赛目标失败"})
		return
	}
	if err := h.db.Where("user_id = ?", userID).First(&preference).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取竞赛目标失败"})
		return
	}
	c.JSON(http.StatusOK, competitionPreferenceResponseFromModel(preference))
}

func ensureJSONBodyEnded(decoder *json.Decoder) error {
	var extra interface{}
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("存在额外 JSON 数据")
		}
		return err
	}
	return nil
}

func normalizeCompetitionPreferenceInput(input competitionPreferenceInput) (competitionPreferenceInput, error) {
	input.Goals = cleanPreferenceValues(input.Goals)
	input.DirectionTags = cleanPreferenceValues(input.DirectionTags)
	input.SkillTags = cleanPreferenceValues(input.SkillTags)
	input.PreferredRoles = cleanPreferenceValues(input.PreferredRoles)
	input.CareerDirection = strings.TrimSpace(input.CareerDirection)
	input.ExperienceLevel = strings.TrimSpace(input.ExperienceLevel)
	if input.ExperienceLevel == "" {
		input.ExperienceLevel = "beginner"
	}
	if len(input.Goals) > 3 {
		return input, errors.New("用户目标最多选择 3 个")
	}
	if len(input.DirectionTags) > 8 {
		return input, errors.New("比赛方向最多选择 8 个")
	}
	if len(input.SkillTags) > 12 {
		return input, errors.New("技能方向最多选择 12 个")
	}
	if len(input.PreferredRoles) > 3 {
		return input, errors.New("偏好角色最多选择 3 个")
	}
	if err := validatePreferenceEnums(input.Goals, competitionPreferenceGoals, "用户目标"); err != nil {
		return input, err
	}
	if err := validatePreferenceEnums(input.PreferredRoles, competitionPreferenceRoles, "偏好角色"); err != nil {
		return input, err
	}
	if _, ok := competitionExperienceLevels[input.ExperienceLevel]; !ok {
		return input, errors.New("未知的竞赛经验等级")
	}
	if input.WeeklyHours < 0 || input.WeeklyHours > 40 {
		return input, errors.New("每周投入时间必须在 0 到 40 小时之间")
	}
	if utf8.RuneCountInString(input.CareerDirection) > 80 {
		return input, errors.New("职业方向最多 80 个字")
	}
	for _, value := range append(append([]string{}, input.DirectionTags...), input.SkillTags...) {
		if utf8.RuneCountInString(value) > 30 {
			return input, errors.New("单个方向或技能标签最多 30 个字")
		}
	}
	return input, nil
}

func cleanPreferenceValues(values []string) []string {
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

func validatePreferenceEnums(values []string, allowed map[string]struct{}, field string) error {
	for _, value := range values {
		if _, ok := allowed[value]; !ok {
			return fmt.Errorf("%s包含未知选项：%s", field, value)
		}
	}
	return nil
}
