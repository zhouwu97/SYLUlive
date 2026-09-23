package ai

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"gorm.io/gorm"

	"shenliyuan/internal/competitioncontext"
	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

var ErrCompetitionAIExplanationDisabled = errors.New("competition AI explanation disabled")

// BuildHy3CompetitionUserContext 在专项授权关闭时直接失败，不构造外部模型画像。
func BuildHy3CompetitionUserContext(
	ctx context.Context,
	db *gorm.DB,
	userID uint,
) (competitioncontext.UserContext, error) {
	var user models.User
	if err := db.WithContext(ctx).
		Select("id", "competition_profile_ai_enabled").
		First(&user, userID).Error; err != nil {
		return competitioncontext.UserContext{}, err
	}
	if !user.CompetitionProfileAIEnabled {
		return competitioncontext.UserContext{}, ErrCompetitionAIExplanationDisabled
	}
	return competitioncontext.NewBuilder(db).
		BuildCompetitionUserContext(ctx, userID)
}

type Hy3CompetitionReason struct {
	Text         string   `json:"text"`
	SourceFields []string `json:"source_fields"`
}

type Hy3CompetitionExplanationItem struct {
	CompetitionID      string                 `json:"competition_id"`
	CoreReason         string                 `json:"core_reason"`
	Reasons            []Hy3CompetitionReason `json:"reasons"`
	Cautions           []Hy3CompetitionReason `json:"cautions"`
	QuestionsToConfirm []string               `json:"questions_to_confirm"`
}

type Hy3CompetitionExplanation struct {
	Summary string                          `json:"summary"`
	Items   []Hy3CompetitionExplanationItem `json:"items"`
}

type Hy3SelectedCompetitionComparisonItem struct {
	CompetitionID      string                 `json:"competition_id"`
	Observations       []Hy3CompetitionReason `json:"observations"`
	Cautions           []Hy3CompetitionReason `json:"cautions"`
	QuestionsToConfirm []string               `json:"questions_to_confirm"`
}

type Hy3SelectedCompetitionComparison struct {
	Summary string                                 `json:"summary"`
	Items   []Hy3SelectedCompetitionComparisonItem `json:"items"`
}

var allowedHy3CompetitionSourceFields = map[string]struct{}{
	"competition_level": {}, "school_recognition_status": {}, "school_recognition_grade": {},
	"competition_rating": {}, "participation_type": {}, "team_size_min": {}, "team_size_max": {},
	"registration_time_text": {}, "event_time_text": {}, "time_status": {},
	"manual_rating_reason_public": {}, "major_fit_summary_public": {},
	"evidence_summary_public": {}, "evidence_subgrade": {}, "risk_tags": {},
	"match_dimensions": {}, "gates": {},
}

var forbiddenHy3CompetitionLanguage = []string{
	"最适合", "强烈推荐", "获奖概率", "成功率", "综合分", "第一名", "top 1", "top1",
}

var newHy3DatePattern = regexp.MustCompile(`20\d{2}(?:[-/.年]\d{1,2})`)
var probabilityPattern = regexp.MustCompile(`\d+(?:\.\d+)?%`)
var hy3PositiveRecognitionPattern = regexp.MustCompile(`(已|已经|确已|正式)(被)?(学校)?(认定|认可)|(已|已经)(获|获得)学校认可|通过认定|认定赛事`)
var hy3NegativeRecognitionPattern = regexp.MustCompile(`(未|没有|尚未)(被)?(学校)?(认定|认可)|(未|尚未)通过认定|(未|尚未)(获|获得)学校认可|不(被)?(学校)?(认定|认可)`)
var hy3TeamSizePattern = regexp.MustCompile(`([0-9]{1,3})\s*(人|名)(一组|组成)?`)
var hy3RecognitionGradePattern = regexp.MustCompile(`([a-cA-C])级(?:认定|赛事)?`)

// ValidateHy3CompetitionExplanation 保证模型只能逐项解释既有候选，不能新增或重排。
func ValidateHy3CompetitionExplanation(
	input []dto.CompetitionCandidateDTO,
	output Hy3CompetitionExplanation,
) error {
	if len(output.Items) != len(input) {
		return fmt.Errorf("ai_explanation_item_count_invalid")
	}
	seen := make(map[string]struct{}, len(output.Items))
	for index, item := range output.Items {
		if item.CompetitionID != input[index].CompetitionID {
			return fmt.Errorf("ai_explanation_order_or_id_invalid")
		}
		if _, exists := seen[item.CompetitionID]; exists {
			return fmt.Errorf("ai_explanation_duplicate_id")
		}
		seen[item.CompetitionID] = struct{}{}
		for _, reason := range append(append(
			[]Hy3CompetitionReason{}, item.Reasons...), item.Cautions...) {
			if strings.TrimSpace(reason.Text) == "" || len(reason.SourceFields) == 0 {
				return fmt.Errorf("ai_explanation_source_missing")
			}
			for _, field := range reason.SourceFields {
				if _, allowed := allowedHy3CompetitionSourceFields[field]; !allowed {
					return fmt.Errorf("ai_explanation_source_invalid")
				}
			}
			if err := validateHy3CompetitionText(reason.Text); err != nil {
				return err
			}
		}
		if err := validateHy3CompetitionText(item.CoreReason); err != nil {
			return err
		}
		for _, question := range item.QuestionsToConfirm {
			if err := validateHy3CompetitionText(question); err != nil {
				return err
			}
		}
	}
	return validateHy3CompetitionText(output.Summary)
}

// ValidateHy3CompetitionExplanationFacts 在结构校验之外核对高风险事实。
// 来源字段白名单只能说明模型引用了哪个字段，不能证明文字与字段值一致；
// 认定状态等门槛事实必须在离开服务端前再按候选原值校验。
func ValidateHy3CompetitionExplanationFacts(
	input []dto.CompetitionCandidateDTO,
	output Hy3CompetitionExplanation,
) error {
	if len(input) != len(output.Items) {
		return fmt.Errorf("ai_explanation_item_count_invalid")
	}
	if err := validateHy3CompetitionFactClaims(output.Summary, "", nil); err != nil {
		return err
	}
	for index, item := range output.Items {
		candidate := input[index]
		for _, reason := range append(append([]Hy3CompetitionReason{}, item.Reasons...), item.Cautions...) {
			if err := validateHy3CompetitionCandidateFacts(reason.Text, candidate, reason.SourceFields); err != nil {
				return err
			}
		}
		if err := validateHy3CompetitionCandidateFacts(item.CoreReason, candidate, nil); err != nil {
			return err
		}
		for _, question := range item.QuestionsToConfirm {
			if err := validateHy3CompetitionCandidateFacts(question, candidate, nil); err != nil {
				return err
			}
		}
	}
	return nil
}

// ValidateHy3SelectedCompetitionComparison 保证主动对比只覆盖用户所选赛事并保持选择顺序。
func ValidateHy3SelectedCompetitionComparison(
	expectedIDs []string,
	output Hy3SelectedCompetitionComparison,
) error {
	if len(output.Items) != len(expectedIDs) {
		return fmt.Errorf("ai_comparison_item_count_invalid")
	}
	seen := make(map[string]struct{}, len(output.Items))
	for index, item := range output.Items {
		if item.CompetitionID != expectedIDs[index] {
			return fmt.Errorf("ai_comparison_order_or_id_invalid")
		}
		if _, exists := seen[item.CompetitionID]; exists {
			return fmt.Errorf("ai_comparison_duplicate_id")
		}
		seen[item.CompetitionID] = struct{}{}
		for _, reason := range append(append(
			[]Hy3CompetitionReason{}, item.Observations...), item.Cautions...) {
			if strings.TrimSpace(reason.Text) == "" || len(reason.SourceFields) == 0 {
				return fmt.Errorf("ai_comparison_source_missing")
			}
			for _, field := range reason.SourceFields {
				if _, allowed := allowedHy3CompetitionSourceFields[field]; !allowed {
					return fmt.Errorf("ai_comparison_source_invalid")
				}
			}
			if err := validateHy3CompetitionText(reason.Text); err != nil {
				return err
			}
		}
		for _, question := range item.QuestionsToConfirm {
			if err := validateHy3CompetitionText(question); err != nil {
				return err
			}
		}
	}
	return validateHy3CompetitionText(output.Summary)
}

// ValidateHy3SelectedCompetitionComparisonFacts 与候选解释使用同一套事实门槛。
func ValidateHy3SelectedCompetitionComparisonFacts(
	input []dto.CompetitionCandidateDTO,
	output Hy3SelectedCompetitionComparison,
) error {
	if len(input) != len(output.Items) {
		return fmt.Errorf("ai_comparison_item_count_invalid")
	}
	if err := validateHy3CompetitionFactClaims(output.Summary, "", nil); err != nil {
		return err
	}
	for index, item := range output.Items {
		candidate := input[index]
		for _, reason := range append(append([]Hy3CompetitionReason{}, item.Observations...), item.Cautions...) {
			if err := validateHy3CompetitionCandidateFacts(reason.Text, candidate, reason.SourceFields); err != nil {
				return err
			}
		}
		for _, question := range item.QuestionsToConfirm {
			if err := validateHy3CompetitionCandidateFacts(question, candidate, nil); err != nil {
				return err
			}
		}
	}
	return nil
}

func validateHy3CompetitionFactClaims(text, recognitionStatus string, sourceFields []string) error {
	normalized := strings.ToLower(strings.TrimSpace(text))
	// 先识别否定再从文本中移除否定片段，避免“未通过认定”同时命中“通过认定”。
	negative := hy3NegativeRecognitionPattern.MatchString(normalized)
	positiveText := hy3NegativeRecognitionPattern.ReplaceAllString(normalized, "")
	positive := hy3PositiveRecognitionPattern.MatchString(positiveText)
	// 单纯询问状态不是事实断言；带“既然/因为/确认”等前提的提问仍按断言校验。
	interrogative := strings.ContainsAny(normalized, "?？") &&
		!strings.ContainsAny(normalized, "既然因为确认已知根据")
	if interrogative {
		positive, negative = false, false
	}
	confirmed := schoolRecognitionConfirmed(recognitionStatus)
	knownNegative := schoolRecognitionExplicitlyNegative(recognitionStatus)
	// 没有携带认定字段时仍禁止确定性认定结论，避免模型把 CoreReason
	// 当成不受来源校验的自由文本出口。
	if len(sourceFields) == 0 && (positive || negative) {
		return fmt.Errorf("ai_explanation_fact_conflict")
	}
	if (positive || negative) && !containsHy3SourceField(sourceFields, "school_recognition_status") {
		return fmt.Errorf("ai_explanation_fact_conflict")
	}
	if positive && !confirmed {
		return fmt.Errorf("ai_explanation_fact_conflict")
	}
	if negative && !knownNegative {
		return fmt.Errorf("ai_explanation_fact_conflict")
	}
	return nil
}

func validateHy3CompetitionCandidateFacts(text string, candidate dto.CompetitionCandidateDTO, sourceFields []string) error {
	if err := validateHy3CompetitionFactClaims(text, candidate.SchoolRecognitionStatus, sourceFields); err != nil {
		return err
	}
	normalized := strings.ToLower(strings.TrimSpace(text))
	if matches := hy3TeamSizePattern.FindStringSubmatch(normalized); len(matches) > 0 {
		if !containsHy3SourceField(sourceFields, "team_size_min") && !containsHy3SourceField(sourceFields, "team_size_max") {
			return fmt.Errorf("ai_explanation_fact_conflict")
		}
		teamSize, _ := strconv.Atoi(matches[1])
		if candidate.TeamSizeMin <= 0 && candidate.TeamSizeMax <= 0 {
			return fmt.Errorf("ai_explanation_fact_conflict")
		}
		if candidate.TeamSizeMin > 0 && teamSize < candidate.TeamSizeMin {
			return fmt.Errorf("ai_explanation_fact_conflict")
		}
		if candidate.TeamSizeMax > 0 && teamSize > candidate.TeamSizeMax {
			return fmt.Errorf("ai_explanation_fact_conflict")
		}
	}
	for _, level := range []string{"国际级", "国家级", "省级", "市级", "校级", "院级"} {
		if strings.Contains(normalized, level) {
			if !containsHy3SourceField(sourceFields, "competition_level") ||
				strings.TrimSpace(candidate.CompetitionLevel) == "" ||
				!strings.Contains(strings.ToLower(candidate.CompetitionLevel), strings.ToLower(level)) {
				return fmt.Errorf("ai_explanation_fact_conflict")
			}
		}
	}
	for _, participation := range []string{"团队赛", "个人赛"} {
		if strings.Contains(normalized, participation) &&
			(!containsHy3SourceField(sourceFields, "participation_type") ||
				!strings.Contains(strings.ToLower(candidate.ParticipationType), strings.ToLower(participation))) {
			return fmt.Errorf("ai_explanation_fact_conflict")
		}
	}
	if matches := hy3RecognitionGradePattern.FindStringSubmatch(normalized); len(matches) > 0 {
		grade := strings.ToLower(matches[1])
		if !containsHy3SourceField(sourceFields, "school_recognition_grade") ||
			!strings.Contains(strings.ToLower(candidate.SchoolRecognitionGrade), grade) {
			return fmt.Errorf("ai_explanation_fact_conflict")
		}
	}
	return nil
}

func containsHy3SourceField(fields []string, expected string) bool {
	for _, field := range fields {
		if strings.TrimSpace(field) == expected {
			return true
		}
	}
	return false
}

func schoolRecognitionExplicitlyNegative(status string) bool {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "not_recognized", "unrecognized", "rejected", "未认定", "不认定", "未通过认定":
		return true
	default:
		return false
	}
}

func validateHy3CompetitionText(value string) error {
	normalized := strings.ToLower(strings.TrimSpace(value))
	for _, forbidden := range forbiddenHy3CompetitionLanguage {
		if strings.Contains(normalized, forbidden) {
			return fmt.Errorf("ai_explanation_forbidden_language")
		}
	}
	if newHy3DatePattern.MatchString(normalized) || probabilityPattern.MatchString(normalized) {
		return fmt.Errorf("ai_explanation_new_fact_invalid")
	}
	return nil
}
