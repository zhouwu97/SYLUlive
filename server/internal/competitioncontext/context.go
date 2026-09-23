package competitioncontext

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type CapabilitySummary struct {
	Name              string `json:"name"`
	VerifiedCount     int    `json:"verified_count"`
	SelfReportedCount int    `json:"self_reported_count"`
}

// CompetitionUserContext 是候选筛选与外部解释共用的脱敏结构化画像。
type UserContext struct {
	ProfileVersion string   `json:"profile_version"`
	EntryYear      string   `json:"-"`
	Grade          string   `json:"grade"`
	College        string   `json:"college"`
	Major          string   `json:"major"`
	Goals          []string `json:"goals"`
	DirectionTags  []string `json:"direction_tags"`
	// SkillTags 是用户在偏好页选择的技能标签（受控词表）。
	// 与 Skills 不是一回事：Skills 是从获奖经历汇总的能力画像，
	// SkillTags 是用户自述的技能偏好，用于「技能与赛事方向是否相符」的打分。
	SkillTags              []string            `json:"skill_tags"`
	Skills                 []CapabilitySummary `json:"skills"`
	Roles                  []CapabilitySummary `json:"roles"`
	PreferredRoles         []string            `json:"preferred_roles"`
	WeeklyHours            int                 `json:"weekly_hours"`
	AcceptLongTermTraining bool                `json:"accept_long_term_training"`
	CareerDirection        string              `json:"career_direction"`
	ExperienceLevel        string              `json:"experience_level"`
	// MajorClusterOverride 是用户手动纠正的专业簇，优先于按专业名推断的结果。
	MajorClusterOverride []string `json:"major_cluster_override"`
	ProfileProvenance    string   `json:"-"`
	ProfileReady         bool     `json:"-"`
	PreferenceConfigured bool     `json:"-"`
}

// MissingProfileFields 列出画像就绪所缺的字段，供前端给出可操作的引导。
// 返回空切片表示画像已就绪。顺序固定，便于前端与测试稳定断言。
func (c UserContext) MissingProfileFields() []string {
	if c.ProfileReady {
		return []string{}
	}
	result := make([]string, 0, 4)
	if c.EntryYear == "" {
		result = append(result, "entry_year")
	}
	if c.College == "" {
		result = append(result, "college")
	}
	if c.Major == "" {
		result = append(result, "major")
	}
	if len(result) == 0 {
		// 三项都填了却仍未就绪，只可能是身份核验没过。
		result = append(result, "academic_identity")
	}
	return result
}

type Builder struct {
	db *gorm.DB
}

func NewBuilder(db *gorm.DB) *Builder {
	return &Builder{db: db}
}

// BuildCompetitionUserContext 只读取结构化字段和经历计数，绝不读取材料、经历原文或审核备注。
func (b *Builder) BuildCompetitionUserContext(
	ctx context.Context,
	userID uint,
) (UserContext, error) {
	var result UserContext
	result.Goals = []string{}
	result.DirectionTags = []string{}
	result.SkillTags = []string{}
	result.MajorClusterOverride = []string{}
	result.Skills = []CapabilitySummary{}
	result.Roles = []CapabilitySummary{}
	result.PreferredRoles = []string{}

	var user models.User
	if err := b.db.WithContext(ctx).First(&user, userID).Error; err != nil {
		return result, err
	}
	var binding models.AcademicIdentityBinding
	identityErr := models.TrustedAcademicBindingScope(
		b.db.WithContext(ctx).Where("user_id = ?", userID),
	).Order("verified_at DESC, id DESC").First(&binding).Error
	verified := identityErr == nil
	if identityErr != nil && !errors.Is(identityErr, gorm.ErrRecordNotFound) {
		return result, identityErr
	}
	var competitionProfile models.UserCompetitionProfile
	profileErr := b.db.WithContext(ctx).Where("user_id = ?", userID).First(&competitionProfile).Error
	if profileErr != nil && !errors.Is(profileErr, gorm.ErrRecordNotFound) {
		return result, profileErr
	}
	result.Grade = strings.TrimSpace(user.EduGrade)
	legacyEntryYear := competitionEntryYear(result.Grade, time.Now())
	result.EntryYear = legacyEntryYear
	result.College = strings.TrimSpace(user.EduCollege)
	result.Major = strings.TrimSpace(user.EduMajor)
	if profileErr == nil {
		if value := strings.TrimSpace(competitionProfile.EntryYear); value != "" {
			result.EntryYear = value
		}
		if value := strings.TrimSpace(competitionProfile.College); value != "" {
			result.College = value
		}
		if value := strings.TrimSpace(competitionProfile.Major); value != "" {
			result.Major = value
		}
		result.ProfileProvenance = competitionProfile.Provenance
	}
	if result.Grade == "" {
		level := "本科"
		if binding.ProviderID == models.AcademicProviderGraduate {
			level = "研究生"
		}
		result.Grade = level + result.EntryYear + "级"
	}
	if result.ProfileProvenance == "" && result.EntryYear != "" && result.College != "" && result.Major != "" && verified {
		result.ProfileProvenance = "school_verified"
	}
	result.ProfileReady = verified &&
		result.EntryYear != "" && result.College != "" && result.Major != ""

	var preference models.UserCompetitionPreference
	err := b.db.WithContext(ctx).Where("user_id = ?", userID).First(&preference).Error
	if err == nil {
		result.PreferenceConfigured = true
		result.Goals = decodeCompetitionStringArray(preference.Goals)
		result.DirectionTags = decodeCompetitionStringArray(preference.DirectionTags)
		result.SkillTags = decodeCompetitionStringArray(preference.SkillTags)
		result.PreferredRoles = decodeCompetitionStringArray(preference.PreferredRoles)
		result.WeeklyHours = preference.WeeklyHours
		result.AcceptLongTermTraining = preference.AcceptLongTermTraining
		result.CareerDirection = strings.TrimSpace(preference.CareerDirection)
		result.ExperienceLevel = strings.TrimSpace(preference.ExperienceLevel)
		result.MajorClusterOverride = decodeCompetitionStringArray(preference.MajorClusterOverride)
	} else if !errors.Is(err, gorm.ErrRecordNotFound) {
		return result, err
	}

	var awards []models.UserCompetitionAward
	if err := b.db.WithContext(ctx).
		Select("verification_status", "skill_tags", "role").
		Where("user_id = ? AND verification_status IN ?", userID, []string{"verified", "self_reported"}).
		Order("id ASC").
		Find(&awards).Error; err != nil {
		return result, err
	}
	result.Skills = summarizeCompetitionCapabilities(awards, true)
	result.Roles = summarizeCompetitionCapabilities(awards, false)
	result.ProfileVersion = competitionContextVersion(result)
	return result, nil
}

func summarizeCompetitionCapabilities(
	awards []models.UserCompetitionAward,
	skills bool,
) []CapabilitySummary {
	counts := make(map[string]*CapabilitySummary)
	for _, award := range awards {
		values := []string{strings.TrimSpace(award.Role)}
		if skills {
			values = decodeCompetitionStringArray(award.SkillTags)
		}
		seen := make(map[string]struct{})
		for _, value := range values {
			value = strings.TrimSpace(value)
			if value == "" {
				continue
			}
			key := strings.ToLower(value)
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
			entry := counts[key]
			if entry == nil {
				entry = &CapabilitySummary{Name: value}
				counts[key] = entry
			}
			if award.VerificationStatus == "verified" {
				entry.VerifiedCount++
			} else {
				entry.SelfReportedCount++
			}
		}
	}
	keys := make([]string, 0, len(counts))
	for key := range counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := make([]CapabilitySummary, 0, len(keys))
	for _, key := range keys {
		result = append(result, *counts[key])
	}
	return result
}

func competitionContextVersion(value UserContext) string {
	value.ProfileVersion = ""
	value.ProfileReady = false
	value.PreferenceConfigured = false
	encoded, _ := json.Marshal(value)
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:])
}

var competitionYearPattern = regexp.MustCompile(`(20\d{2})`)

func competitionEntryYear(grade string, now time.Time) string {
	match := competitionYearPattern.FindString(strings.TrimSpace(grade))
	if match != "" {
		return match
	}
	numberPattern := regexp.MustCompile(`(?:大|本科)([一二三四1234])`)
	matchParts := numberPattern.FindStringSubmatch(strings.TrimSpace(grade))
	if len(matchParts) != 2 {
		return ""
	}
	offsets := map[string]int{"一": 0, "1": 0, "二": 1, "2": 1, "三": 2, "3": 2, "四": 3, "4": 3}
	academicYear := now.Year()
	if now.Month() < time.September {
		academicYear--
	}
	return strconv.Itoa(academicYear - offsets[matchParts[1]])
}

func decodeCompetitionStringArray(value datatypes.JSON) []string {
	if len(value) == 0 {
		return []string{}
	}
	var result []string
	if err := json.Unmarshal(value, &result); err != nil || result == nil {
		return []string{}
	}
	return result
}
