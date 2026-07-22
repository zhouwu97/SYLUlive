package handlers

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

type competitionPreferenceMatch struct {
	Score            int
	PreferencePoints int
	TimePoints       int
	ValuePoints      int
	Tier             string
	Reasons          []string
}

func (h *CompetitionHandler) loadCompetitionPreference(userID uint) (models.UserCompetitionPreference, bool, error) {
	var preference models.UserCompetitionPreference
	if err := h.db.Where("user_id = ?", userID).First(&preference).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return preference, false, nil
		}
		return preference, false, err
	}
	return preference, true, nil
}

func matchCompetitionPreference(
	event models.CompetitionEvent,
	profileLevel string,
	preference models.UserCompetitionPreference,
) competitionPreferenceMatch {
	goals := decodeStringArray(preference.Goals)
	directions := decodeStringArray(preference.DirectionTags)
	skills := decodeStringArray(preference.SkillTags)
	roles := decodeStringArray(preference.PreferredRoles)
	text := competitionSearchableText(event)

	directionMatches := matchingPreferenceValues(directions, text)
	skillMatches := matchingPreferenceValues(skills, text)
	roleMatches := matchingCompetitionRoles(roles, text)
	preferencePoints := minInt(len(directionMatches)*8, 16) + minInt(len(skillMatches)*5, 10) + minInt(len(roleMatches)*6, 12)
	reasons := make([]string, 0, 6)
	if len(directionMatches) > 0 {
		reasons = appendUniqueReason(reasons, "与你关注的"+directionMatches[0]+"方向一致")
	}
	if len(skillMatches) > 0 {
		reasons = appendUniqueReason(reasons, "与你的"+skillMatches[0]+"技能方向相关")
	}
	if len(roleMatches) > 0 {
		reasons = appendUniqueReason(reasons, "包含你偏好的"+competitionRoleReasonLabel(roleMatches[0])+"角色方向")
	}

	goalPoints := 0
	for _, goal := range goals {
		switch goal {
		case "resume":
			if recommendationRanks[effectiveCompetitionRating(event)] >= recommendationRanks["B+"] || event.ImportanceScore >= 70 {
				goalPoints += 8
				reasons = appendUniqueReason(reasons, "赛事价值符合简历提升目标")
			}
		case "ability":
			if len(directionMatches)+len(skillMatches)+len(roleMatches) > 0 {
				goalPoints += 8
				reasons = appendUniqueReason(reasons, "与你的能力成长目标一致")
			}
		case "exploration":
			goalPoints += 5
			reasons = appendUniqueReason(reasons, "适合探索新的竞赛方向")
		case "postgraduate":
			if event.SchoolRecognitionStatus == "recognized" || recommendationRanks[effectiveCompetitionRating(event)] >= recommendationRanks["A"] {
				goalPoints += 10
				reasons = appendUniqueReason(reasons, "学校认定或赛事价值符合保研准备目标")
			}
		case "graduation_gap":
			// 毕业预警数据源尚未接入，该目标只保存，不参与收益或推荐加分。
		}
	}
	goalPoints = minInt(goalPoints, 16)
	preferencePoints += goalPoints

	career := strings.TrimSpace(preference.CareerDirection)
	if career != "" && strings.Contains(text, strings.ToLower(career)) {
		preferencePoints += 6
		reasons = appendUniqueReason(reasons, "与你填写的职业方向相关")
	}

	timePoints := 0
	if preference.WeeklyHours > 0 {
		requiredHours := estimatedCompetitionWeeklyHours(event, text)
		if preference.WeeklyHours >= requiredHours {
			timePoints += 8
			reasons = appendUniqueReason(reasons, "适合"+weeklyHoursReason(preference.WeeklyHours)+"投入")
		}
	}
	if longTerm, known := isLongTermCompetition(event); known {
		if longTerm && preference.AcceptLongTermTraining {
			timePoints += 4
			reasons = appendUniqueReason(reasons, "接受该赛事的长期准备周期")
		} else if !longTerm && !preference.AcceptLongTermTraining {
			timePoints += 4
			reasons = appendUniqueReason(reasons, "准备周期符合短期项目偏好")
		}
	}

	valuePoints := competitionValuePoints(event)
	profilePoints := map[string]int{"major": 40, "college": 32, "general": 24}[profileLevel]
	score := minInt(profilePoints+preferencePoints+timePoints+valuePoints, 100)
	tier := "explore"
	if score >= 70 {
		tier = "recommended"
	} else if score >= 50 {
		tier = "suitable"
	}
	return competitionPreferenceMatch{
		Score: score, PreferencePoints: preferencePoints, TimePoints: timePoints,
		ValuePoints: valuePoints, Tier: tier, Reasons: reasons,
	}
}

func competitionSearchableText(event models.CompetitionEvent) string {
	parts := []string{
		event.Title, event.Subtitle, event.Summary, event.Description, event.TargetAudience,
		event.ParticipationType, event.CompetitionLevel,
	}
	if event.PrimaryCategory != nil {
		parts = append(parts, event.PrimaryCategory.Name, event.PrimaryCategory.Slug)
	}
	parts = append(parts, decodeStringArray(event.Tags)...)
	return strings.ToLower(strings.Join(parts, " "))
}

func matchingPreferenceValues(values []string, text string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" && strings.Contains(text, strings.ToLower(value)) {
			result = append(result, value)
		}
	}
	return result
}

var competitionRoleKeywords = map[string][]string{
	"developer": {"程序", "软件", "编程", "开发", "算法", "代码"},
	"modeler":   {"建模", "数学模型", "仿真"},
	"hardware":  {"硬件", "电子", "嵌入式", "电路", "单片机"},
	"designer":  {"设计", "视觉", "交互", "艺术"},
	"writer":    {"文案", "写作", "策划", "商业计划书"},
	"presenter": {"答辩", "演讲", "路演", "展示"},
	"organizer": {"组织", "管理", "项目管理", "协调"},
}

func matchingCompetitionRoles(roles []string, text string) []string {
	result := make([]string, 0, len(roles))
	for _, role := range roles {
		for _, keyword := range competitionRoleKeywords[role] {
			if strings.Contains(text, keyword) {
				result = append(result, role)
				break
			}
		}
	}
	return result
}

func competitionRoleReasonLabel(role string) string {
	labels := map[string]string{
		"developer": "开发", "modeler": "建模", "hardware": "硬件", "designer": "设计",
		"writer": "文案", "presenter": "答辩", "organizer": "组织",
	}
	return labels[role]
}

func estimatedCompetitionWeeklyHours(event models.CompetitionEvent, text string) int {
	if longTerm, known := isLongTermCompetition(event); known && longTerm {
		return 14
	}
	if strings.Contains(text, "训练") || strings.Contains(text, "联赛") || strings.Contains(text, "赛季") {
		return 14
	}
	participation := strings.TrimSpace(event.ParticipationType)
	if event.TeamSizeMax == 1 || (strings.Contains(participation, "个人") && !strings.Contains(participation, "团队")) {
		return 3
	}
	return 7
}

func isLongTermCompetition(event models.CompetitionEvent) (bool, bool) {
	var start, end *time.Time
	if event.RegistrationStart != nil {
		start = event.RegistrationStart
	} else if event.EventStart != nil {
		start = event.EventStart
	}
	if event.EventEnd != nil {
		end = event.EventEnd
	} else if event.RegistrationEnd != nil {
		end = event.RegistrationEnd
	}
	if start == nil || end == nil || !end.After(*start) {
		return false, false
	}
	return end.Sub(*start) >= 60*24*time.Hour, true
}

func weeklyHoursReason(hours int) string {
	switch hours {
	case 3:
		return "每周 1～3 小时"
	case 7:
		return "每周 4～7 小时"
	case 14:
		return "每周 8～14 小时"
	case 20:
		return "每周 15 小时以上"
	default:
		return fmt.Sprintf("每周 %d 小时", hours)
	}
}

func competitionValuePoints(event models.CompetitionEvent) int {
	points := 0
	switch effectiveCompetitionRating(event) {
	case "S", "A":
		points += 4
	case "B+", "B":
		points += 2
	case "B-", "C":
		points++
	}
	if event.ImportanceScore >= 80 {
		points += 2
	} else if event.ImportanceScore >= 50 {
		points++
	}
	return minInt(points, 6)
}

func appendUniqueReason(reasons []string, reason string) []string {
	for _, existing := range reasons {
		if existing == reason {
			return reasons
		}
	}
	return append(reasons, reason)
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}
