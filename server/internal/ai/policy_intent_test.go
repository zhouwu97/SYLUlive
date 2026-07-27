package ai

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBuildPolicyQueryPlanSeparatesFailedCourseIntents(t *testing.T) {
	tests := []struct {
		question string
		intent   string
	}{
		{question: "补考成绩怎么算", intent: PolicyIntentSecondExamGrade},
		{question: "补考考100分多少绩点", intent: PolicyIntentSecondExamGrade},
		{question: "挂科以后补考成绩怎么算", intent: PolicyIntentSecondExamGrade},
		{question: "实验课挂科能补考吗", intent: PolicyIntentPracticeFailure},
		{question: "课程设计没过怎么办", intent: PolicyIntentPracticeFailure},
		{question: "补考没过怎么办", intent: PolicyIntentRetakeTransition},
		{question: "二考没过还能怎么办", intent: PolicyIntentRetakeTransition},
		{question: "重修有什么规定", intent: PolicyIntentRetake},
		{question: "刷分怎么弄", intent: PolicyIntentRetake},
		{question: "开学补考什么时候", intent: PolicyIntentSecondExam},
		{question: "怎么参加补考", intent: PolicyIntentSecondExam},
		{question: "挂科了怎么办", intent: PolicyIntentFailedCourse},
		{question: "没拿到学分怎么办", intent: PolicyIntentFailedCourse},
		{question: "学校怎么申请休学", intent: PolicyIntentGeneral},
	}
	for _, test := range tests {
		t.Run(test.question, func(t *testing.T) {
			require.Equal(t, test.intent, BuildPolicyQueryPlan(test.question).Intent)
		})
	}
}

func TestFailedCourseFlowPlanRequiresStatusAndRetakeEvidence(t *testing.T) {
	plan := BuildPolicyQueryPlan("挂科了怎么办")
	require.Equal(t, PolicyIntentFailedCourse, plan.Intent)
	require.Contains(t, plan.ExpandedQuery, "首次考核不合格")
	require.Contains(t, plan.ExpandedQuery, "二次考试")
	require.Contains(t, plan.ExpandedQuery, "课程重修")
	require.Equal(t, HistoricalPolicyFallback, plan.HistoricalMode)
	require.Equal(t, [][]string{
		{DocTypeStatusPolicy, DocTypeReasoningCard},
		{DocTypeRetakePolicy},
	}, plan.RequiredDocGroups)
	require.Equal(t, []string{
		AnswerSectionCurrentRule,
		AnswerSectionSecondExamBranch,
		AnswerSectionRetakeBranch,
		AnswerSectionSpecialCourseBoundary,
	}, plan.RequiredAnswerSections)
}

func TestRetakePlanExcludesMakeupExamTermsAndHistory(t *testing.T) {
	plan := BuildPolicyQueryPlan("重修有什么规定")
	require.Equal(t, PolicyIntentRetake, plan.Intent)
	require.Contains(t, plan.ExactTerms, "课程重修")
	require.NotContains(t, plan.ExpandedQuery, "补考")
	require.NotContains(t, plan.ExpandedQuery, "二次考试")
	require.Equal(t, HistoricalPolicyNone, plan.HistoricalMode)
	require.False(t, plan.AllowsHistorical())
	require.NotContains(t, plan.PreferredDocTypes, DocTypeHistoricalSecondExam)
}

func TestSecondExamGradePlanRequiresHistoricalEvidence(t *testing.T) {
	plan := BuildPolicyQueryPlan("补考成绩怎么算")
	require.Equal(t, PolicyIntentSecondExamGrade, plan.Intent)
	require.Equal(t, HistoricalPolicyRequired, plan.HistoricalMode)
	require.True(t, plan.AllowsHistorical())
	require.Contains(t, plan.RequiredDocGroups, []string{DocTypeHistoricalSecondExam})
	require.Contains(t, plan.ExactTerms, "二次考试成绩")
	require.NotContains(t, plan.ExactTerms, "原平时成绩")
	require.NotContains(t, plan.ExactTerms, "等级为D或F")
	require.NotContains(t, plan.ExactTerms, "绩点为1或0")
}

func TestPracticeCourseFailurePlanKeepsBoundaryEvidence(t *testing.T) {
	plan := BuildPolicyQueryPlan("实验课挂科能补考吗")
	require.Equal(t, PolicyIntentPracticeFailure, plan.Intent)
	require.Contains(t, plan.ExpandedQuery, "首次考核不合格")
	require.Contains(t, plan.ExpandedQuery, "实践教学环节")
	require.Contains(t, plan.RequiredDocGroups, []string{DocTypeRetakePolicy})
	require.Contains(t, plan.RequiredAnswerSections, AnswerSectionSpecialCourseBoundary)
	require.Equal(t, HistoricalPolicyFallback, plan.HistoricalMode)
}

func TestRetakeTransitionPlanBridgesSecondExamToRetake(t *testing.T) {
	plan := BuildPolicyQueryPlan("补考没过怎么办")
	require.Equal(t, PolicyIntentRetakeTransition, plan.Intent)
	require.Contains(t, plan.ExpandedQuery, "二考未取得学分")
	require.Contains(t, plan.ExpandedQuery, "课程重修")
	require.Contains(t, plan.RequiredDocGroups, []string{DocTypeRetakePolicy})
}

func TestBuildPolicyQueryPlanLeavesUnmappedQuestionStable(t *testing.T) {
	plan := BuildPolicyQueryPlan("学校怎么申请休学")
	require.Equal(t, PolicyIntentGeneral, plan.Intent)
	require.Equal(t, "学校怎么申请休学", plan.ExpandedQuery)
	require.Empty(t, plan.RequiredDocGroups)
	require.False(t, plan.IsPolicyIntent())
}

func TestPolicyDocumentPreferenceKeepsCurrentRulesAheadOfHistory(t *testing.T) {
	plan := BuildPolicyQueryPlan("挂科了怎么办")
	status := policyDocumentPreferenceBonus(plan, DocTypeStatusPolicy)
	retake := policyDocumentPreferenceBonus(plan, DocTypeRetakePolicy)
	card := policyDocumentPreferenceBonus(plan, DocTypeReasoningCard)
	competition := policyDocumentPreferenceBonus(plan, "school_competition_course_grade_reward_policy")
	historical := policyDocumentPreferenceBonus(plan, DocTypeHistoricalSecondExam)
	require.Greater(t, status, retake)
	require.Greater(t, retake, card)
	require.Greater(t, card, competition)
	require.Negative(t, historical, "fallback 模式下历史文件只能兜底")

	// required 模式把历史文件列为偏好类型，不再受负分惩罚。
	gradePlan := BuildPolicyQueryPlan("补考成绩怎么算")
	require.Positive(t, policyDocumentPreferenceBonus(gradePlan, DocTypeHistoricalSecondExam))
}

func TestGeneralPolicyQueryPenalizesUnrequestedHistoricalDocuments(t *testing.T) {
	plan := BuildPolicyQueryPlan("如何申请休学")
	require.Equal(t, -2, policyDocumentPreferenceBonus(plan, DocTypeHistoricalSecondExam))
}
