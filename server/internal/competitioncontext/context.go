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
	ProfileVersion         string              `json:"profile_version"`
	EntryYear              string              `json:"-"`
	Grade                  string              `json:"grade"`
	College                string              `json:"college"`
	Major                  string              `json:"major"`
	Goals                  []string            `json:"goals"`
	DirectionTags          []string            `json:"direction_tags"`
	Skills                 []CapabilitySummary `json:"skills"`
	Roles                  []CapabilitySummary `json:"roles"`
	PreferredRoles         []string            `json:"preferred_roles"`
	WeeklyHours            int                 `json:"weekly_hours"`
	AcceptLongTermTraining bool                `json:"accept_long_term_training"`
	CareerDirection        string              `json:"career_direction"`
	ExperienceLevel        string              `json:"experience_level"`
	ProfileReady           bool                `json:"-"`
	PreferenceConfigured   bool                `json:"-"`
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
	result.Skills = []CapabilitySummary{}
	result.Roles = []CapabilitySummary{}
	result.PreferredRoles = []string{}

	var user models.User
	if err := b.db.WithContext(ctx).First(&user, userID).Error; err != nil {
		return result, err
	}
	result.Grade = strings.TrimSpace(user.EduGrade)
	result.EntryYear = competitionEntryYear(result.Grade, time.Now())
	result.College = strings.TrimSpace(user.EduCollege)
	result.Major = strings.TrimSpace(user.EduMajor)
	result.ProfileReady = user.IsStudentVerified() &&
		result.EntryYear != "" && result.College != "" && result.Major != ""

	var preference models.UserCompetitionPreference
	err := b.db.WithContext(ctx).Where("user_id = ?", userID).First(&preference).Error
	if err == nil {
		result.PreferenceConfigured = true
		result.Goals = decodeCompetitionStringArray(preference.Goals)
		result.DirectionTags = decodeCompetitionStringArray(preference.DirectionTags)
		result.PreferredRoles = decodeCompetitionStringArray(preference.PreferredRoles)
		result.WeeklyHours = preference.WeeklyHours
		result.AcceptLongTermTraining = preference.AcceptLongTermTraining
		result.CareerDirection = strings.TrimSpace(preference.CareerDirection)
		result.ExperienceLevel = strings.TrimSpace(preference.ExperienceLevel)
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
