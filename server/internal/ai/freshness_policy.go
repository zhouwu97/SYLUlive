package ai

import (
	"strings"

	"shenliyuan/internal/academic"
)

// FreshnessPolicy 是服务端对个人数据新鲜度的最低要求。
// 模型可以请求更严格的策略，但不能把服务端要求降级为旧数据。
type FreshnessPolicy struct {
	Preference    academic.FreshnessPreference
	MaxAgeSeconds int
}

const (
	gradesTTLSeconds    = 5 * 60
	scheduleTTLSeconds  = 10 * 60
	situationTTLSeconds = 6 * 60 * 60
	creditTTLSeconds    = 24 * 60 * 60
	erkeTTLSeconds      = 30 * 60
)

// ResolveFreshnessPolicy 根据稳定的业务意图和数据集计算服务端最低策略。
// reason 来自受控工具调用，不接受模型自由拼接的用户可见文案。
func ResolveFreshnessPolicy(reason string, datasets []academic.DatasetType, question string) FreshnessPolicy {
	reason = strings.TrimSpace(reason)
	question = strings.TrimSpace(question)
	if explicitlyAllowsStale(question) {
		return FreshnessPolicy{Preference: academic.FreshnessAllowStale, MaxAgeSeconds: maxDatasetTTL(datasets)}
	}
	if strings.Contains(question, "历史") || strings.Contains(question, "上学期") || strings.Contains(question, "某学期") {
		return FreshnessPolicy{Preference: academic.FreshnessPreferRecent, MaxAgeSeconds: maxDatasetTTL(datasets)}
	}
	switch reason {
	case "credit_summary", "credit_requirements", "history_grade_summary":
		return FreshnessPolicy{Preference: academic.FreshnessPreferRecent, MaxAgeSeconds: maxDatasetTTL(datasets)}
	default:
		// 当前学业风险、当前成绩、当前课程和当前空闲时间都必须先验证新鲜度。
		return FreshnessPolicy{Preference: academic.FreshnessRequireFresh, MaxAgeSeconds: maxDatasetTTL(datasets)}
	}
}

// EffectiveFreshness 只允许调用方提升新鲜度要求。
func EffectiveFreshness(server, requested academic.FreshnessPreference) academic.FreshnessPreference {
	if freshnessRank(requested) > freshnessRank(server) {
		return requested
	}
	return server
}

func freshnessRank(value academic.FreshnessPreference) int {
	switch value {
	case academic.FreshnessAllowStale:
		return 0
	case academic.FreshnessPreferRecent:
		return 1
	case academic.FreshnessRequireFresh:
		return 2
	default:
		return -1
	}
}

func explicitlyAllowsStale(question string) bool {
	return strings.Contains(question, "按已有数据") ||
		strings.Contains(question, "基于已有数据") ||
		strings.Contains(question, "不用更新") ||
		strings.Contains(question, "不需要最新")
}

func maxDatasetTTL(datasets []academic.DatasetType) int {
	max := gradesTTLSeconds
	for _, dataset := range datasets {
		value := switchDatasetTTL(dataset)
		if value > max {
			max = value
		}
	}
	return max
}

func switchDatasetTTL(dataset academic.DatasetType) int {
	switch dataset {
	case academic.DatasetSchedule:
		return scheduleTTLSeconds
	case academic.DatasetAcademicSituation:
		return situationTTLSeconds
	case academic.DatasetCreditRequirements, academic.DatasetCreditSummary:
		return creditTTLSeconds
	case academic.DatasetErke:
		return erkeTTLSeconds
	default:
		return gradesTTLSeconds
	}
}
