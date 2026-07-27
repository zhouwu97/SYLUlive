package ai

import "strings"

// PolicyQueryPlan 是 Python PolicyQueryPlanner 的内部兼容契约；Go 不再维护领域意图规则。
type PolicyQueryPlan struct {
	SchemaVersion     string   `json:"schema_version"`
	PlannerName       string   `json:"planner_name"`
	PlannerVersion    string   `json:"planner_version"`
	Intent            string   `json:"intent"`
	NormalizedQuery   string   `json:"normalized_question"`
	ExactTerms        []string `json:"exact_terms"`
	ExpandedTerms     []string `json:"expanded_terms"`
	PreferredDocTypes []string `json:"preferred_document_types"`
	HistoryPolicy     string   `json:"history_policy"`
	VersionBoundary   string   `json:"version_boundary"`
	AllowHistorical   bool     `json:"allow_historical"`
}

func (p PolicyQueryPlan) retrievalQuery() string {
	values := make([]string, 0, 1+len(p.ExactTerms)+len(p.ExpandedTerms))
	values = append(values, p.NormalizedQuery)
	values = append(values, p.ExactTerms...)
	values = append(values, p.ExpandedTerms...)
	return strings.Join(values, " ")
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
