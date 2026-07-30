package ai

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

func TestBuildHy3CompetitionUserContextStopsBeforeProfileWhenAuthorizationOff(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:hy3-context-off?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&models.User{}))
	user := models.User{StudentID: "hy3-off", PasswordHash: "test", Nickname: "关闭授权"}
	require.NoError(t, db.Create(&user).Error)

	_, err = BuildHy3CompetitionUserContext(context.Background(), db, user.ID)
	require.ErrorIs(t, err, ErrCompetitionAIExplanationDisabled)
}

func TestBuildHy3CompetitionUserContextUsesUnifiedStructuredProfile(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:hy3-context-on?mode=memory&cache=shared"), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(
		&models.User{}, &models.UserCompetitionPreference{}, &models.UserCompetitionAward{},
	))
	now := time.Now()
	user := models.User{
		StudentID: "hy3-on", PasswordHash: "test", Nickname: "开启授权",
		CompetitionProfileAIEnabled: true, StudentVerifiedAt: &now,
		EduGrade: "本科2023级", EduCollege: "信息学院", EduMajor: "软件工程",
	}
	require.NoError(t, db.Create(&user).Error)

	profile, err := BuildHy3CompetitionUserContext(context.Background(), db, user.ID)
	require.NoError(t, err)
	require.Equal(t, "软件工程", profile.Major)
	require.Equal(t, "信息学院", profile.College)
	require.NotEmpty(t, profile.ProfileVersion)
}

func TestValidateHy3CompetitionExplanationRejectsAddedReorderedAndUntrustedOutput(t *testing.T) {
	input := []dto.CompetitionCandidateDTO{
		{CompetitionPublicDTO: dto.CompetitionPublicDTO{CompetitionID: "NAT-001"}},
		{CompetitionPublicDTO: dto.CompetitionPublicDTO{CompetitionID: "NAT-002"}},
	}
	valid := Hy3CompetitionExplanation{
		Summary: "两个候选分别侧重软件实践与团队协作。",
		Items: []Hy3CompetitionExplanationItem{
			{
				CompetitionID: "NAT-001", CoreReason: "与你的专业方向相关",
				Reasons: []Hy3CompetitionReason{{
					Text: "专业适配信息明确", SourceFields: []string{"major_fit_summary_public"},
				}},
			},
			{
				CompetitionID: "NAT-002", CoreReason: "符合当前参赛资格",
				Cautions: []Hy3CompetitionReason{{
					Text: "需要稳定队友", SourceFields: []string{"risk_tags"},
				}},
			},
		},
	}
	require.NoError(t, ValidateHy3CompetitionExplanation(input, valid))

	reordered := valid
	reordered.Items = append([]Hy3CompetitionExplanationItem{}, valid.Items...)
	reordered.Items[0], reordered.Items[1] = reordered.Items[1], reordered.Items[0]
	require.Error(t, ValidateHy3CompetitionExplanation(input, reordered))

	untrusted := valid
	untrusted.Items = append([]Hy3CompetitionExplanationItem{}, valid.Items...)
	untrusted.Items[0].Reasons = []Hy3CompetitionReason{{
		Text: "强烈推荐，获奖概率 82%", SourceFields: []string{"internal_score"},
	}}
	require.Error(t, ValidateHy3CompetitionExplanation(input, untrusted))
}

func TestValidateHy3SelectedCompetitionComparisonRejectsReorderAndUntrustedSource(t *testing.T) {
	valid := Hy3SelectedCompetitionComparison{
		Summary: "两项赛事的公开事实各有侧重。",
		Items: []Hy3SelectedCompetitionComparisonItem{
			{
				CompetitionID: "NAT-001",
				Observations: []Hy3CompetitionReason{{
					Text: "赛事价值有公开目录依据", SourceFields: []string{"competition_rating"},
				}},
				Cautions:           []Hy3CompetitionReason{},
				QuestionsToConfirm: []string{},
			},
			{
				CompetitionID: "NAT-002",
				Observations: []Hy3CompetitionReason{{
					Text: "认定状态可以直接核对", SourceFields: []string{"school_recognition_status"},
				}},
				Cautions:           []Hy3CompetitionReason{},
				QuestionsToConfirm: []string{},
			},
		},
	}
	require.NoError(t, ValidateHy3SelectedCompetitionComparison(
		[]string{"NAT-001", "NAT-002"}, valid,
	))

	reordered := valid
	reordered.Items = append([]Hy3SelectedCompetitionComparisonItem{}, valid.Items...)
	reordered.Items[0], reordered.Items[1] = reordered.Items[1], reordered.Items[0]
	require.Error(t, ValidateHy3SelectedCompetitionComparison(
		[]string{"NAT-001", "NAT-002"}, reordered,
	))

	untrusted := valid
	untrusted.Items = append([]Hy3SelectedCompetitionComparisonItem{}, valid.Items...)
	untrusted.Items[0].Observations = []Hy3CompetitionReason{{
		Text: "综合分 95", SourceFields: []string{"internal_score"},
	}}
	require.Error(t, ValidateHy3SelectedCompetitionComparison(
		[]string{"NAT-001", "NAT-002"}, untrusted,
	))
}

func TestCompetitionAIExplanationDisabledSentinel(t *testing.T) {
	require.True(t, errors.Is(ErrCompetitionAIExplanationDisabled, ErrCompetitionAIExplanationDisabled))
}
