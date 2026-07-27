package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestV08FocusRoutesAreSpecific(t *testing.T) {
	cases := []struct {
		question string
		intent   string
		focus    string
	}{
		{"重修几门", PolicyIntentRetake, PolicyFocusCourseLimit},
		{"重修成绩怎么算", PolicyIntentRetake, PolicyFocusGradeRecording},
		{"重修怎么报名", PolicyIntentRetake, PolicyFocusRegistrationPayment},
		{"重修和正常课程冲突", PolicyIntentRetake, PolicyFocusScheduleConflict},
		{"交不起学费", PolicyIntentFinancialDifficulty, PolicyFocusTuition},
		{"没钱吃饭", PolicyIntentFinancialDifficulty, PolicyFocusLiving},
		{"国家励志奖学金和国家奖学金能一起拿吗", PolicyIntentScholarship, PolicyFocusCompatibility},
		{"挂科影响奖学金吗", PolicyIntentScholarship, PolicyFocusEligibility},
		{"勤工助学允许挂几科", PolicyIntentWorkStudy, PolicyFocusEligibility},
	}
	for _, test := range cases {
		t.Run(test.question, func(t *testing.T) {
			plan := BuildPolicyQueryPlan(test.question)
			require.Equal(t, test.intent, plan.Intent)
			require.Equal(t, test.focus, plan.Focus)
			require.Equal(t, PolicyBreadthFocused, plan.Breadth)
		})
	}
}

func TestV08ScholarshipWinsOverFailedCourseFlow(t *testing.T) {
	plan := BuildPolicyQueryPlan("挂科了怎么办，奖学金还能评吗")
	require.Equal(t, PolicyIntentScholarship, plan.Intent)
	require.NotContains(t, plan.RequiredAnswerSections, AnswerSectionRetakeBranch)
}

func TestV08MixedPolicyQuestionsFollowSharedPriority(t *testing.T) {
	cases := []struct {
		question string
		intent   string
	}{
		{"有两科不及格还能勤工助学吗", PolicyIntentWorkStudy},
		{"国家助学金和国家奖学金冲突吗", PolicyIntentScholarship},
	}
	for _, test := range cases {
		t.Run(test.question, func(t *testing.T) {
			require.Equal(t, test.intent, BuildPolicyQueryPlan(test.question).Intent)
		})
	}
}

func TestV08RetakeFeeDifficultyCombinesAidAndRetakeEvidence(t *testing.T) {
	plan := BuildPolicyQueryPlan("重修费交不起怎么办")

	require.Equal(t, PolicyIntentFinancialDifficulty, plan.Intent)
	require.Equal(t, PolicyFocusTuition, plan.Focus)
	require.Contains(t, plan.PreferredDocTypes, DocTypeStudentLoan)
	require.Contains(t, plan.PreferredDocTypes, DocTypeRetakePolicy)
	require.Contains(t, plan.RequiredDocGroups, []string{DocTypeRetakePolicy})
	require.Contains(t, plan.RequiredAnswerSections, AnswerSectionRetakeBranch)
}
