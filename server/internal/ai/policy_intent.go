package ai

import "strings"

// PolicyQueryPlan 将学生口语确定性映射为可审计的制度检索计划。
type PolicyQueryPlan struct {
	Intent            string
	OriginalQuery     string
	ExpandedQuery     string
	ExactTerms        []string
	PreferredDocTypes []string
	AllowHistorical   bool
}

type policyTermExpansion struct {
	trigger string
	terms   []string
}

var policyTermExpansions = []policyTermExpansion{
	{trigger: "挂科", terms: []string{"首次考核不合格", "未取得学分"}},
	{trigger: "补考", terms: []string{"二次考试", "二考"}},
	{trigger: "开学补考", terms: []string{"开学初", "二次考试"}},
	{trigger: "补考绩点", terms: []string{"二考成绩", "等级为D或F", "绩点为1或0"}},
	{trigger: "补考没过", terms: []string{"二考未取得学分", "重修"}},
	{trigger: "补考未过", terms: []string{"二考未取得学分", "重修"}},
	{trigger: "刷分", terms: []string{"成绩合格", "继续修读", "提升成绩", "重修"}},
	{trigger: "二次考试", terms: []string{"补考", "二考"}},
	{trigger: "二考", terms: []string{"二次考试", "补考"}},
	{trigger: "重修", terms: []string{"重新学习", "课程重修"}},
}

func BuildPolicyQueryPlan(question string) PolicyQueryPlan {
	question = strings.TrimSpace(question)
	plan := PolicyQueryPlan{Intent: "general_policy", OriginalQuery: question, ExpandedQuery: question}
	terms := make([]string, 0, 12)
	seen := make(map[string]struct{})
	add := func(value string) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		if _, exists := seen[value]; exists {
			return
		}
		seen[value] = struct{}{}
		terms = append(terms, value)
	}
	for _, expansion := range policyTermExpansions {
		if !strings.Contains(question, expansion.trigger) {
			continue
		}
		plan.Intent = "second_exam_and_retake"
		add(expansion.trigger)
		for _, term := range expansion.terms {
			add(term)
		}
	}
	if strings.Contains(question, "补考") &&
		(strings.Contains(question, "成绩") || strings.Contains(question, "绩点") || strings.Contains(question, "怎么算")) {
		plan.Intent = "second_exam_grade"
		add("二考成绩")
		add("及格 不及格")
		add("等级为D或F")
		add("绩点为1或0")
	}
	if plan.Intent == "second_exam_and_retake" {
		configureSecondExamPlan(&plan, add)
	} else if plan.Intent == "second_exam_grade" {
		configureSecondExamPlan(&plan, add)
	}
	plan.ExactTerms = terms
	if len(terms) > 0 {
		plan.ExpandedQuery = strings.TrimSpace(question + " " + strings.Join(terms, " "))
	}
	return plan
}

func configureSecondExamPlan(plan *PolicyQueryPlan, add func(string)) {
	if plan == nil {
		return
	}
	// 补考问题需要组合现行学籍、重修规则卡；历史文件只能补充现行文件未写明的细节。
	plan.PreferredDocTypes = []string{
		"school_policy_reasoning_card",
		"school_undergraduate_retake_policy",
		"school_undergraduate_status_policy",
		"historical_school_second_exam_policy",
	}
	plan.AllowHistorical = true
	add("首次考核不合格")
	add("二次考试")
	add("二考")
	add("重修")
}

func policyDocumentPreferenceBonus(plan PolicyQueryPlan, docType string) int {
	for i, t := range plan.PreferredDocTypes {
		if t == docType {
			return len(plan.PreferredDocTypes) - i
		}
	}
	if !plan.AllowHistorical && strings.Contains(docType, "historical") {
		return -1
	}
	return 0
}
