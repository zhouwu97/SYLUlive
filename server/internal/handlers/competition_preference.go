package handlers

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/competitionmatching"
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
	Goals                  []string                 `json:"goals"`
	DirectionTags          []string                 `json:"direction_tags"`
	SkillTags              []string                 `json:"skill_tags"`
	PreferredRoles         []string                 `json:"preferred_roles"`
	WeeklyHours            int                      `json:"weekly_hours"`
	AcceptLongTermTraining bool                     `json:"accept_long_term_training"`
	CareerDirection        string                   `json:"career_direction"`
	ExperienceLevel        string                   `json:"experience_level"`
	CompetitionProfile     *competitionProfileInput `json:"competition_profile"`
	// MajorClusterOverride 用指针区分「没传」与「传了空数组」：
	// 本接口是整体覆盖语义，若把「没传」当成「清空」，
	// 尚未升级的客户端每次保存偏好都会静默抹掉用户已填的专业纠正。
	MajorClusterOverride *[]string `json:"major_cluster_override"`
}

type competitionProfileInput struct {
	EntryYear string `json:"entry_year"`
	College   string `json:"college"`
	Major     string `json:"major"`
}

type competitionProfileResponse struct {
	EntryYear  string     `json:"entry_year"`
	College    string     `json:"college"`
	Major      string     `json:"major"`
	Provenance string     `json:"provenance"`
	UpdatedAt  *time.Time `json:"updated_at"`
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
	MajorClusterOverride   []string `json:"major_cluster_override"`
	// MajorClusterOptions 是服务端下发的专业簇词表，供客户端渲染可纠正的专业方向。
	MajorClusterOptions []string                   `json:"major_cluster_options"`
	CompetitionProfile  competitionProfileResponse `json:"competition_profile"`
}

func defaultCompetitionPreferenceResponse() competitionPreferenceResponse {
	return competitionPreferenceResponse{
		Goals: []string{}, DirectionTags: []string{}, SkillTags: []string{}, PreferredRoles: []string{},
		MajorClusterOverride: []string{},
		MajorClusterOptions:  competitionmatching.ClusterOptions(),
		ExperienceLevel:      "beginner",
		CompetitionProfile:   competitionProfileResponse{},
	}
}

func competitionProfileResponseFromModel(profile *models.UserCompetitionProfile) competitionProfileResponse {
	if profile == nil {
		return competitionProfileResponse{}
	}
	return competitionProfileResponse{
		EntryYear: profile.EntryYear, College: profile.College, Major: profile.Major,
		Provenance: profile.Provenance, UpdatedAt: &profile.UpdatedAt,
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
		MajorClusterOverride:   decodeStringArray(preference.MajorClusterOverride),
		MajorClusterOptions:    competitionmatching.ClusterOptions(),
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
			response := defaultCompetitionPreferenceResponse()
			var profile models.UserCompetitionProfile
			if profileErr := h.db.Where("user_id = ?", userID).First(&profile).Error; profileErr == nil {
				response.CompetitionProfile = competitionProfileResponseFromModel(&profile)
			} else if !errors.Is(profileErr, gorm.ErrRecordNotFound) {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛画像失败"})
				return
			}
			c.JSON(http.StatusOK, response)
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛目标失败"})
		return
	}
	response := competitionPreferenceResponseFromModel(preference)
	var profile models.UserCompetitionProfile
	if err := h.db.Where("user_id = ?", userID).First(&profile).Error; err == nil {
		response.CompetitionProfile = competitionProfileResponseFromModel(&profile)
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "获取竞赛画像失败"})
		return
	}
	c.JSON(http.StatusOK, response)
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
		MajorClusterOverride: jsonArray([]string{}),
	}
	updates := map[string]interface{}{
		"goals": preference.Goals, "direction_tags": preference.DirectionTags,
		"skill_tags": preference.SkillTags, "preferred_roles": preference.PreferredRoles,
		"weekly_hours": preference.WeeklyHours, "accept_long_term_training": preference.AcceptLongTermTraining,
		"career_direction": preference.CareerDirection, "experience_level": preference.ExperienceLevel,
	}
	// 只有显式传了该字段才覆盖，避免旧客户端保存偏好时把用户已填的专业纠正抹掉。
	if normalized.MajorClusterOverride != nil {
		preference.MajorClusterOverride = jsonArray(*normalized.MajorClusterOverride)
		updates["major_cluster_override"] = preference.MajorClusterOverride
	}
	if err := h.db.Transaction(func(tx *gorm.DB) error {
		if err := tx.Clauses(clause.OnConflict{
			Columns: []clause.Column{{Name: "user_id"}}, DoUpdates: clause.Assignments(updates),
		}).Create(&preference).Error; err != nil {
			return err
		}
		if normalized.CompetitionProfile == nil {
			return nil
		}
		profile := normalized.CompetitionProfile
		if profile.EntryYear == "" && profile.College == "" && profile.Major == "" {
			return tx.Where("user_id = ?", userID).Delete(&models.UserCompetitionProfile{}).Error
		}
		profileModel := models.UserCompetitionProfile{
			UserID: userID, EntryYear: profile.EntryYear, College: profile.College, Major: profile.Major,
			Provenance: models.UserCompetitionProfileProvenanceSelfReported, UpdatedAt: time.Now().UTC(),
		}
		return tx.Clauses(clause.OnConflict{
			Columns: []clause.Column{{Name: "user_id"}},
			DoUpdates: clause.Assignments(map[string]interface{}{
				"entry_year": profileModel.EntryYear, "college": profileModel.College,
				"major": profileModel.Major, "provenance": profileModel.Provenance,
				"updated_at": profileModel.UpdatedAt,
			}),
		}).Create(&profileModel).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "保存竞赛目标或画像失败"})
		return
	}
	if err := h.db.Where("user_id = ?", userID).First(&preference).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取竞赛目标失败"})
		return
	}
	response := competitionPreferenceResponseFromModel(preference)
	var profile models.UserCompetitionProfile
	if err := h.db.Where("user_id = ?", userID).First(&profile).Error; err == nil {
		response.CompetitionProfile = competitionProfileResponseFromModel(&profile)
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "读取竞赛画像失败"})
		return
	}
	c.JSON(http.StatusOK, response)
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
	if input.MajorClusterOverride != nil {
		cleaned := cleanPreferenceValues(*input.MajorClusterOverride)
		input.MajorClusterOverride = &cleaned
	}
	input.CareerDirection = strings.TrimSpace(input.CareerDirection)
	input.ExperienceLevel = strings.TrimSpace(input.ExperienceLevel)
	if input.CompetitionProfile != nil {
		profile := *input.CompetitionProfile
		profile.EntryYear = strings.TrimSpace(profile.EntryYear)
		profile.College = strings.TrimSpace(profile.College)
		profile.Major = strings.TrimSpace(profile.Major)
		if profile.EntryYear != "" {
			validYear := len(profile.EntryYear) == 4
			for _, digit := range profile.EntryYear {
				validYear = validYear && digit >= '0' && digit <= '9'
			}
			year, _ := strconv.Atoi(profile.EntryYear)
			if !validYear || year < 1900 || year > time.Now().Year()+1 {
				return input, errors.New("入学年份需为有效的四位年份")
			}
		}
		if utf8.RuneCountInString(profile.College) > 120 || utf8.RuneCountInString(profile.Major) > 120 {
			return input, errors.New("学院和专业名称最多 120 个字")
		}
		input.CompetitionProfile = &profile
	}
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
	if input.MajorClusterOverride != nil && len(*input.MajorClusterOverride) > 3 {
		return input, errors.New("专业方向纠正最多选择 3 个")
	}
	if err := validatePreferenceEnums(input.Goals, competitionPreferenceGoals, "用户目标"); err != nil {
		return input, err
	}
	if err := validatePreferenceEnums(input.PreferredRoles, competitionPreferenceRoles, "偏好角色"); err != nil {
		return input, err
	}
	// 方向与技能必须落在受控词表内：这两个字段直接决定「偏好」分量的命中判定，
	// 写入一个词表外的值不会报错、也不会生效，只会变成用户看不到的死选项。
	if err := validatePreferenceValues(input.DirectionTags, competitionmatching.IsKnownDirection, "比赛方向"); err != nil {
		return input, err
	}
	if err := validatePreferenceValues(input.SkillTags, competitionmatching.IsKnownSkill, "技能方向"); err != nil {
		return input, err
	}
	// 专业方向纠正必须落在目录真实使用的 53 个专业簇内，否则匹配时会被静默丢弃。
	if input.MajorClusterOverride != nil {
		if err := validatePreferenceValues(*input.MajorClusterOverride, competitionmatching.IsStandardCluster, "专业方向纠正"); err != nil {
			return input, err
		}
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

// validatePreferenceValues 用受控词表的判定函数校验取值，
// 适用于词表定义在匹配包（competitionmatching）里的字段，避免两处词表各写一遍而漂移。
func validatePreferenceValues(values []string, allowed func(string) bool, field string) error {
	for _, value := range values {
		if !allowed(value) {
			return fmt.Errorf("%s包含未知选项：%s", field, value)
		}
	}
	return nil
}
