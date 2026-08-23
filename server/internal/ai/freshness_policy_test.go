package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
	"shenliyuan/internal/academic"
)

func TestResolveFreshnessPolicyRequiresFreshForCurrentAcademicQuestions(t *testing.T) {
	policy := ResolveFreshnessPolicy("hy3_academic_analysis", []academic.DatasetType{academic.DatasetGrades}, "分析我目前的学业风险")
	require.Equal(t, academic.FreshnessRequireFresh, policy.Preference)
	require.Equal(t, 5*60, policy.MaxAgeSeconds)
}

func TestResolveFreshnessPolicyAllowsStaleOnlyWhenUserSaysSo(t *testing.T) {
	policy := ResolveFreshnessPolicy("hy3_academic_analysis", []academic.DatasetType{academic.DatasetGrades}, "按已有数据分析")
	require.Equal(t, academic.FreshnessAllowStale, policy.Preference)
}

func TestEffectiveFreshnessCannotBeDowngradedByModel(t *testing.T) {
	require.Equal(t, academic.FreshnessRequireFresh, EffectiveFreshness(academic.FreshnessRequireFresh, academic.FreshnessAllowStale))
	require.Equal(t, academic.FreshnessRequireFresh, EffectiveFreshness(academic.FreshnessPreferRecent, academic.FreshnessRequireFresh))
}
