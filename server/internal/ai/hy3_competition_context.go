package ai

import (
	"context"
	"errors"
	"fmt"
	"regexp"
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
