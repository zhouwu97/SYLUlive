package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBuildPolicyQueryPlanExpandsStudentRetakeLanguage(t *testing.T) {
	plan := BuildPolicyQueryPlan("挂科以后补考成绩怎么算")
	require.Equal(t, "second_exam_grade", plan.Intent)
	require.Contains(t, plan.ExpandedQuery, "首次考核不合格")
	require.Contains(t, plan.ExpandedQuery, "二次考试")
	require.Contains(t, plan.ExpandedQuery, "二考")
	require.Contains(t, plan.ExpandedQuery, "重修")
	require.Contains(t, plan.PreferredDocTypes, "school_policy_reasoning_card")
}

func TestBuildPolicyQueryPlanLeavesUnmappedQuestionStable(t *testing.T) {
	plan := BuildPolicyQueryPlan("学校怎么申请休学")
	require.Equal(t, "general_policy", plan.Intent)
	require.Equal(t, "学校怎么申请休学", plan.ExpandedQuery)
}

func TestBuildPolicyQueryPlanCoversV06RetakeQuestions(t *testing.T) {
	tests := []struct {
		question string
		terms    []string
	}{
		{question: "补考成绩怎么算", terms: []string{"二次考试", "二考"}},
		{question: "补考考100分多少绩点", terms: []string{"二次考试", "二考"}},
		{question: "挂科了怎么办", terms: []string{"首次考核不合格", "重修"}},
		{question: "开学补考什么时候", terms: []string{"开学初", "二次考试"}},
		{question: "补考没过怎么办", terms: []string{"二考未取得学分", "重修"}},
		{question: "实验课挂科能补考吗", terms: []string{"首次考核不合格", "二次考试"}},
		{question: "刷分怎么弄", terms: []string{"成绩合格", "提升成绩", "重修"}},
	}
	for _, test := range tests {
		t.Run(test.question, func(t *testing.T) {
			plan := BuildPolicyQueryPlan(test.question)
			require.Contains(t, []string{"second_exam_and_retake", "second_exam_grade"}, plan.Intent)
			for _, term := range test.terms {
				require.Contains(t, plan.ExpandedQuery, term)
			}
			require.True(t, plan.AllowHistorical)
		})
	}
}

func TestBuildPolicyQueryPlanAddsGradeTermsForMakeupScoreQuestions(t *testing.T) {
	for _, question := range []string{"补考成绩怎么算", "补考考100分多少绩点"} {
		plan := BuildPolicyQueryPlan(question)
		require.Equal(t, "second_exam_grade", plan.Intent)
		require.Contains(t, plan.ExactTerms, "等级为D或F")
		require.Contains(t, plan.ExactTerms, "绩点为1或0")
	}
}

func TestPolicyDocumentPreferenceKeepsCurrentRulesAheadOfHistory(t *testing.T) {
	plan := BuildPolicyQueryPlan("补考成绩怎么算")
	reasoning := policyDocumentPreferenceBonus(plan, "school_policy_reasoning_card")
	currentRetake := policyDocumentPreferenceBonus(plan, "school_undergraduate_retake_policy")
	currentStatus := policyDocumentPreferenceBonus(plan, "school_undergraduate_status_policy")
	historical := policyDocumentPreferenceBonus(plan, "historical_school_second_exam_policy")
	competition := policyDocumentPreferenceBonus(plan, "school_competition_course_grade_reward_policy")
	require.Greater(t, reasoning, currentRetake)
	require.Greater(t, currentRetake, currentStatus)
	require.Greater(t, currentStatus, historical)
	require.Greater(t, historical, competition)
}

func TestGeneralPolicyQueryPenalizesUnrequestedHistoricalDocuments(t *testing.T) {
	plan := BuildPolicyQueryPlan("如何申请休学")
	require.Negative(t, policyDocumentPreferenceBonus(plan, "historical_school_second_exam_policy"))
}
