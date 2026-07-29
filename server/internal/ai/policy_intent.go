package ai

import (
	"sort"
	"strings"
)

// HistoricalPolicyMode 描述历史制度文件在本次检索中的角色。
// 历史文件不是简单的“允许/不允许”：不同问题需要完全不同的处理。
type HistoricalPolicyMode string

const (
	// HistoricalPolicyNone 现行文件足以独立回答，历史口径不得进入证据集合。
	HistoricalPolicyNone HistoricalPolicyMode = "none"
	// HistoricalPolicyFallback 历史文件只能补充现行文件未覆盖的环节，且必须标注版本。
	HistoricalPolicyFallback HistoricalPolicyMode = "fallback"
	// HistoricalPolicyRequired 细节只存在于历史文件，必须召回并明确标注历史边界。
	HistoricalPolicyRequired HistoricalPolicyMode = "required"
)

// 政策意图与知识库 SYLUlive_政策问答意图与同义词_v0.6.json 保持同名。
const (
	PolicyIntentGeneral             = "general_policy"
	PolicyIntentFailedCourse        = "failed_course_flow"
	PolicyIntentSecondExam          = "second_exam"
	PolicyIntentSecondExamGrade     = "second_exam_grade"
	PolicyIntentRetake              = "retake"
	PolicyIntentRetakeTransition    = "retake_transition"
	PolicyIntentPracticeFailure     = "practice_course_failure"
	PolicyIntentFinancialDifficulty = "financial_difficulty_flow"
	PolicyIntentStudentLoan         = "student_loan"
	PolicyIntentWorkStudy           = "work_study"
	PolicyIntentHardshipAid         = "hardship_aid"
	PolicyIntentScholarship         = "scholarship_selection"
	PolicyIntentOrphanAid           = "orphan_aid"
)

// 文档类型与知识库导入包的 document_type 字段保持同名。
const (
	DocTypeStatusPolicy             = "school_undergraduate_status_policy"
	DocTypeRetakePolicy             = "school_undergraduate_retake_policy"
	DocTypeReasoningCard            = "school_policy_reasoning_card"
	DocTypeMakeupExamPractice       = "school_makeup_exam_current_practice"
	DocTypeHistoricalSecondExam     = "historical_school_second_exam_policy"
	DocTypeUndergraduateScholarship = "school_undergraduate_scholarship_policy"
	DocTypeNationalScholarship      = "school_national_scholarship_policy"
	DocTypeNationalInspirational    = "school_national_inspirational_scholarship_policy"
	DocTypeNationalGrant            = "school_national_grant_policy"
	DocTypeHardshipRecognition      = "school_financial_hardship_recognition_policy"
	DocTypeGrantTemporaryAid        = "school_grant_and_temporary_aid_policy"
	DocTypeWorkStudy                = "school_work_study_policy"
	DocTypeStudentLoan              = "school_student_loan_policy"
	DocTypeOrphanAid                = "school_orphan_aid_policy"
)

// 回答分支标识，供生成层校验必答环节是否齐备。
const (
	AnswerSectionCurrentRule           = "current_rule"
	AnswerSectionSecondExamBranch      = "second_exam_branch"
	AnswerSectionRetakeBranch          = "retake_branch"
	AnswerSectionSpecialCourseBoundary = "special_course_boundary"
	AnswerSectionGradeRecording        = "grade_recording"
	AnswerSectionHistoricalBoundary    = "historical_boundary"
)

const (
	PolicyFocusOverview            = "overview"
	PolicyFocusEligibility         = "eligibility"
	PolicyFocusRegistrationPayment = "registration_payment"
	PolicyFocusCourseLimit         = "course_limit"
	PolicyFocusGradeRecording      = "grade_recording"
	PolicyFocusStudyMode           = "study_mode"
	PolicyFocusScheduleConflict    = "schedule_conflict"
	PolicyFocusTuition             = "tuition"
	PolicyFocusLiving              = "living"
	PolicyFocusCompatibility       = "compatibility"
	PolicyFocusAmount              = "amount"
	PolicyBreadthOverview          = "overview"
	PolicyBreadthFocused           = "focused"
)

// PolicyQueryPlan 同时承载 Python Planner 返回值和旧 Go 路径的确定性规划结果。
// Python Planner 是主路径；Go 字段仅用于灰度降级和旧调用方兼容。
type PolicyQueryPlan struct {
	SchemaVersion   string `json:"schema_version,omitempty"`
	PlannerName     string `json:"planner_name,omitempty"`
	PlannerVersion  string `json:"planner_version,omitempty"`
	Intent          string `json:"intent"`
	Focus           string `json:"focus,omitempty"`
	Breadth         string `json:"breadth,omitempty"`
	OriginalQuery   string `json:"original_query,omitempty"`
	NormalizedQuery string `json:"normalized_question,omitempty"`
	ExpandedQuery   string `json:"expanded_query,omitempty"`

	// ExactTerms 用于在向量与全文检索之前做确定性的制度术语命中。
	ExactTerms    []string `json:"exact_terms,omitempty"`
	ExpandedTerms []string `json:"expanded_terms,omitempty"`

	// PreferredDocTypes 只影响排序；RequiredDocGroups 决定必须覆盖的证据组。
	PreferredDocTypes []string   `json:"preferred_document_types,omitempty"`
	RequiredDocGroups [][]string `json:"required_document_groups,omitempty"`

	HistoricalMode  HistoricalPolicyMode `json:"historical_mode,omitempty"`
	HistoryPolicy   string               `json:"history_policy,omitempty"`
	VersionBoundary string               `json:"version_boundary,omitempty"`
	AllowHistorical bool                 `json:"allow_historical"`

	AnswerMode             string   `json:"answer_mode,omitempty"`
	RequiredAnswerSections []string `json:"required_answer_sections,omitempty"`
}

// AllowsHistorical 报告本次检索是否可以引用历史制度文件。
func (p PolicyQueryPlan) AllowsHistorical() bool {
	return p.AllowHistorical || p.HistoricalMode == HistoricalPolicyFallback || p.HistoricalMode == HistoricalPolicyRequired
}

func (p PolicyQueryPlan) retrievalQuery() string {
	if strings.TrimSpace(p.ExpandedQuery) != "" {
		return strings.TrimSpace(p.ExpandedQuery)
	}
	values := make([]string, 0, 1+len(p.ExactTerms)+len(p.ExpandedTerms))
	values = append(values, p.NormalizedQuery)
	values = append(values, p.ExactTerms...)
	values = append(values, p.ExpandedTerms...)
	return strings.TrimSpace(strings.Join(values, " "))
}

// IsPolicyIntent 报告本次问题是否命中了确定性制度意图。
func (p PolicyQueryPlan) IsPolicyIntent() bool {
	return p.Intent != "" && p.Intent != PolicyIntentGeneral
}

type policyTermExpansion struct {
	trigger string
	terms   []string
}

var policyTermExpansions = []policyTermExpansion{
	{trigger: "挂科", terms: []string{"首次考核不合格", "未取得相应学分"}},
	{trigger: "没及格", terms: []string{"首次考核不合格", "未取得相应学分"}},
	{trigger: "不及格", terms: []string{"首次考核不合格", "未取得相应学分"}},
	{trigger: "没拿到学分", terms: []string{"未取得相应学分"}},
	{trigger: "补考", terms: []string{"二次考试", "二考"}},
	{trigger: "开学补考", terms: []string{"开学初", "二次考试"}},
	{trigger: "补考成绩", terms: []string{"二次考试成绩", "成绩记载"}},
	{trigger: "补考绩点", terms: []string{"二次考试成绩", "课程绩点"}},
	{trigger: "刷分", terms: []string{"成绩合格", "提升成绩", "重修"}},
	{trigger: "二次考试", terms: []string{"补考", "二考"}},
	{trigger: "二考", terms: []string{"二次考试", "补考"}},
	{trigger: "重修", terms: []string{"重新学习", "课程重修"}},
	{trigger: "重新学习", terms: []string{"课程重修"}},
}

type policyIntentProfile struct {
	preferredDocTypes []string
	requiredDocGroups [][]string
	historicalMode    HistoricalPolicyMode
	answerMode        string
	answerSections    []string
	canonicalTerms    []string
}

// policyIntentProfiles 是意图到证据组的唯一事实来源。
// RequiredDocGroups 表示“每组至少召回一条”，不是过滤白名单。
var policyIntentProfiles = map[string]policyIntentProfile{
	PolicyIntentFailedCourse: {
		preferredDocTypes: []string{DocTypeStatusPolicy, DocTypeRetakePolicy, DocTypeReasoningCard, DocTypeMakeupExamPractice},
		requiredDocGroups: [][]string{
			{DocTypeStatusPolicy, DocTypeReasoningCard},
			{DocTypeRetakePolicy},
		},
		historicalMode: HistoricalPolicyFallback,
		answerMode:     PolicyIntentFailedCourse,
		answerSections: []string{
			AnswerSectionCurrentRule,
			AnswerSectionSecondExamBranch,
			AnswerSectionRetakeBranch,
			AnswerSectionSpecialCourseBoundary,
		},
		canonicalTerms: []string{"首次考核不合格", "未取得相应学分", "二次考试", "重新学习", "课程重修"},
	},
	PolicyIntentSecondExam: {
		preferredDocTypes: []string{DocTypeMakeupExamPractice, DocTypeReasoningCard, DocTypeStatusPolicy},
		requiredDocGroups: [][]string{
			{DocTypeStatusPolicy, DocTypeReasoningCard, DocTypeMakeupExamPractice},
		},
		historicalMode: HistoricalPolicyFallback,
		answerMode:     PolicyIntentSecondExam,
		answerSections: []string{AnswerSectionCurrentRule, AnswerSectionSecondExamBranch},
		canonicalTerms: []string{"二次考试", "二考", "首次考核不合格", "开学初"},
	},
	PolicyIntentSecondExamGrade: {
		preferredDocTypes: []string{DocTypeMakeupExamPractice, DocTypeReasoningCard, DocTypeHistoricalSecondExam, DocTypeStatusPolicy},
		requiredDocGroups: [][]string{
			{DocTypeReasoningCard, DocTypeMakeupExamPractice},
			{DocTypeHistoricalSecondExam},
			{DocTypeStatusPolicy},
		},
		historicalMode: HistoricalPolicyRequired,
		answerMode:     PolicyIntentSecondExamGrade,
		answerSections: []string{AnswerSectionGradeRecording, AnswerSectionHistoricalBoundary},
		canonicalTerms: []string{"二次考试成绩", "成绩记载", "考核比例"},
	},
	PolicyIntentRetake: {
		preferredDocTypes: []string{DocTypeRetakePolicy, DocTypeReasoningCard},
		requiredDocGroups: [][]string{
			{DocTypeRetakePolicy},
		},
		historicalMode: HistoricalPolicyNone,
		answerMode:     PolicyIntentRetake,
		answerSections: []string{AnswerSectionRetakeBranch},
		canonicalTerms: []string{"课程重修", "重新修读", "重修考核", "最高分记载"},
	},
	PolicyIntentRetakeTransition: {
		preferredDocTypes: []string{DocTypeRetakePolicy, DocTypeStatusPolicy, DocTypeReasoningCard, DocTypeHistoricalSecondExam},
		requiredDocGroups: [][]string{
			{DocTypeStatusPolicy, DocTypeHistoricalSecondExam, DocTypeReasoningCard},
			{DocTypeRetakePolicy},
		},
		historicalMode: HistoricalPolicyFallback,
		answerMode:     PolicyIntentRetakeTransition,
		answerSections: []string{AnswerSectionCurrentRule, AnswerSectionRetakeBranch},
		canonicalTerms: []string{"二考未取得学分", "课程重修", "缴费重修", "重新学习"},
	},
	PolicyIntentPracticeFailure: {
		preferredDocTypes: []string{DocTypeRetakePolicy, DocTypeStatusPolicy, DocTypeReasoningCard, DocTypeHistoricalSecondExam},
		requiredDocGroups: [][]string{
			{DocTypeStatusPolicy, DocTypeReasoningCard},
			{DocTypeRetakePolicy},
			{DocTypeHistoricalSecondExam},
		},
		historicalMode: HistoricalPolicyFallback,
		answerMode:     PolicyIntentPracticeFailure,
		answerSections: []string{
			AnswerSectionCurrentRule,
			AnswerSectionSpecialCourseBoundary,
			AnswerSectionRetakeBranch,
		},
		canonicalTerms: []string{"实践教学环节", "实验", "课程设计", "课程重修", "首次考核不合格"},
	},
}

// PolicyIntents 返回所有确定性制度意图，用于与知识库配置比对。
func PolicyIntents() []string {
	intents := make([]string, 0, len(policyIntentProfiles))
	for intent := range policyIntentProfiles {
		intents = append(intents, intent)
	}
	sort.Strings(intents)
	return intents
}

// BuildPolicyQueryPlan 按固定优先级识别意图。
// 顺序很重要：“挂科以后补考成绩怎么算”应命中成绩记载，而不是宽泛流程。
func BuildPolicyQueryPlan(question string) PolicyQueryPlan {
	question = strings.TrimSpace(question)
	plan := PolicyQueryPlan{
		Intent:         PolicyIntentGeneral,
		Focus:          PolicyFocusOverview,
		Breadth:        PolicyBreadthOverview,
		OriginalQuery:  question,
		ExpandedQuery:  question,
		HistoricalMode: HistoricalPolicyNone,
	}
	if question == "" {
		return plan
	}
	plan.Intent = detectPolicyIntent(question)
	plan.Focus = detectPolicyFocus(question, plan.Intent)
	if plan.Focus != PolicyFocusOverview {
		plan.Breadth = PolicyBreadthFocused
	}

	terms := make([]string, 0, 16)
	seen := make(map[string]struct{}, 16)
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
		add(expansion.trigger)
		for _, term := range expansion.terms {
			add(term)
		}
	}
	for _, alias := range activePolicyContract.Aliases {
		if !strings.Contains(question, alias.Trigger) {
			continue
		}
		add(alias.Trigger)
		for _, term := range alias.Terms {
			add(term)
		}
	}

	if profile, ok := policyIntentProfiles[plan.Intent]; ok {
		plan.PreferredDocTypes = append([]string(nil), profile.preferredDocTypes...)
		plan.RequiredDocGroups = copyDocGroups(profile.requiredDocGroups)
		plan.HistoricalMode = profile.historicalMode
		plan.AnswerMode = profile.answerMode
		plan.RequiredAnswerSections = append([]string(nil), profile.answerSections...)
		for _, term := range profile.canonicalTerms {
			add(term)
		}
	}
	if isRetakeFinancialQuestion(question) {
		retakeProfile := policyIntentProfiles[PolicyIntentRetake]
		plan.PreferredDocTypes = appendUniqueStrings(plan.PreferredDocTypes, retakeProfile.preferredDocTypes...)
		plan.RequiredDocGroups = append(plan.RequiredDocGroups, copyDocGroups(retakeProfile.requiredDocGroups)...)
		plan.RequiredAnswerSections = appendUniqueStrings(plan.RequiredAnswerSections, retakeProfile.answerSections...)
		for _, term := range retakeProfile.canonicalTerms {
			add(term)
		}
	}

	// 明确的重修问题不得把补考术语带入检索，否则会用历史二考细则替代现行重修办法。
	if plan.Intent == PolicyIntentRetake {
		terms = dropTerms(terms, "补考", "二考", "二次考试", "二次考试成绩")
	}

	plan.ExactTerms = terms
	if len(terms) > 0 {
		plan.ExpandedQuery = strings.TrimSpace(question + " " + strings.Join(terms, " "))
	}
	return plan
}

func detectPolicyIntent(question string) string {
	matchedAliases := make(map[string]struct{})
	for _, alias := range activePolicyContract.Aliases {
		if strings.Contains(question, alias.Trigger) {
			matchedAliases[alias.Intent] = struct{}{}
		}
	}
	for _, intent := range activePolicyContract.IntentPriority {
		if _, matched := matchedAliases[intent]; matched {
			return intent
		}
	}

	// 先识别制度对象；挂科、成绩和费用在资助问题中只是资格修饰条件。
	if containsAny(question, "奖学金", "奖学金评选", "奖学金评审") {
		return PolicyIntentScholarship
	}
	if containsAny(question, "勤工助学", "勤工俭学") {
		return PolicyIntentWorkStudy
	}
	if containsAny(question, "助学贷款", "生源地贷款", "校园地贷款") {
		return PolicyIntentStudentLoan
	}
	if containsAny(question, "孤儿资助", "孤儿减免") {
		return PolicyIntentOrphanAid
	}
	if containsAny(question, "困难认定", "校助学金", "临时困难补助", "国家助学金") {
		return PolicyIntentHardshipAid
	}
	if containsAny(question, "没钱", "交不起学费", "生活费不够", "没钱吃饭") {
		return PolicyIntentFinancialDifficulty
	}
	failure := containsAny(question, "挂科", "没及格", "不及格", "不合格", "没过", "未通过", "没通过", "没拿到学分", "未取得学分", "考砸")
	makeupExam := containsAny(question, "补考", "二考", "二次考试")
	retake := containsAny(question, "重修", "重新学习", "重新修读", "刷分")
	practiceCourse := containsAny(question, "实验", "实践", "课程设计", "实习", "上机", "毕业设计", "实训")
	if retake && isRetakeFinancialQuestion(question) {
		return PolicyIntentFinancialDifficulty
	}

	// 1. 补考成绩与绩点是记载口径问题，优先于宽泛流程。
	if makeupExam && containsAny(question, "成绩", "绩点", "怎么算", "如何算", "多少分", "分数", "记载", "算几分") {
		return PolicyIntentSecondExamGrade
	}
	// 2. 特殊课程边界必须先于普通补考流程识别，避免承诺可以参加普通补考。
	if practiceCourse && (failure || makeupExam || retake) {
		return PolicyIntentPracticeFailure
	}
	// 3. 二考失败过渡：问题主体是补考之后怎么办。
	if makeupExam && failure {
		return PolicyIntentRetakeTransition
	}
	// 4. 明确的重修问题。
	if retake && !makeupExam {
		return PolicyIntentRetake
	}
	// 5. 明确的补考问题。
	if makeupExam {
		return PolicyIntentSecondExam
	}
	// 6. 宽泛的挂科流程问题。
	if failure {
		return PolicyIntentFailedCourse
	}
	return PolicyIntentGeneral
}

func detectPolicyFocus(question, intent string) string {
	if intent == PolicyIntentFinancialDifficulty && isRetakeFinancialQuestion(question) {
		return PolicyFocusTuition
	}
	for _, rule := range activePolicyContract.FocusRules {
		if rule.Intent == intent && containsAny(question, rule.Triggers...) {
			return rule.Focus
		}
	}
	return PolicyFocusOverview
}

func isRetakeFinancialQuestion(question string) bool {
	return containsAny(question, "重修", "重新学习", "重新修读") &&
		containsAny(question, "交不起", "付不起", "没钱", "费用困难")
}

func appendUniqueStrings(values []string, additions ...string) []string {
	seen := make(map[string]struct{}, len(values)+len(additions))
	for _, value := range values {
		seen[value] = struct{}{}
	}
	for _, value := range additions {
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		values = append(values, value)
	}
	return values
}

func copyDocGroups(groups [][]string) [][]string {
	if len(groups) == 0 {
		return nil
	}
	copied := make([][]string, len(groups))
	for index, group := range groups {
		copied[index] = append([]string(nil), group...)
	}
	return copied
}

func dropTerms(terms []string, unwanted ...string) []string {
	if len(terms) == 0 || len(unwanted) == 0 {
		return terms
	}
	blocked := make(map[string]struct{}, len(unwanted))
	for _, term := range unwanted {
		blocked[term] = struct{}{}
	}
	kept := make([]string, 0, len(terms))
	for _, term := range terms {
		if _, found := blocked[term]; found {
			continue
		}
		kept = append(kept, term)
	}
	return kept
}

func isHistoricalDocType(docType string) bool {
	return strings.HasPrefix(strings.TrimSpace(docType), "historical")
}

// policyDocumentPreferenceBonus 只用于排序，不用于过滤。
// 正数表示本意图偏好的文档类型，负数表示当前意图不应引用的历史口径。
func policyDocumentPreferenceBonus(plan PolicyQueryPlan, docType string) int {
	docType = strings.TrimSpace(docType)
	if docType == "" {
		return 0
	}
	for index, preferred := range plan.PreferredDocTypes {
		if preferred == docType {
			return len(plan.PreferredDocTypes) - index
		}
	}
	if isHistoricalDocType(docType) {
		switch plan.HistoricalMode {
		case HistoricalPolicyRequired:
			return 0
		case HistoricalPolicyFallback:
			return -1
		default:
			return -2
		}
	}
	return 0
}
