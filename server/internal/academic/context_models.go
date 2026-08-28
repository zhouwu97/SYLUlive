package academic

import (
	"fmt"
	"strings"
	"time"
)

// DatasetType 是 AcademicContextResolver 可解析的数据集，不暴露数据库或爬虫实现。
type DatasetType string

const (
	DatasetGrades             DatasetType = "grades"
	DatasetSchedule           DatasetType = "schedule"
	DatasetAcademicSituation  DatasetType = "academic_situation"
	DatasetCreditRequirements DatasetType = "credit_requirements"
	DatasetCreditSummary      DatasetType = "credit_summary"
	DatasetErke               DatasetType = "erke"
	DatasetPhysical           DatasetType = "physical"
)

// Valid 判断数据集是否可由统一上下文解析器处理。
func (dataset DatasetType) Valid() bool {
	switch dataset {
	case DatasetGrades,
		DatasetSchedule,
		DatasetAcademicSituation,
		DatasetCreditRequirements,
		DatasetCreditSummary,
		DatasetErke,
		DatasetPhysical:
		return true
	default:
		return false
	}
}

// FreshnessPreference 描述调用者对新鲜度的要求。
type FreshnessPreference string

const (
	FreshnessPreferRecent FreshnessPreference = "prefer_recent"
	FreshnessRequireFresh FreshnessPreference = "require_fresh"
	FreshnessAllowStale   FreshnessPreference = "allow_stale"
)

// ResolveContextRequest 是 academic.resolve_context 的稳定请求模型。
type ResolveContextRequest struct {
	Datasets               []DatasetType       `json:"datasets"`
	Freshness              FreshnessPreference `json:"freshness"`
	Reason                 string              `json:"reason"`
	ScheduleWeekContaining string              `json:"schedule_week_containing,omitempty"`
}

// Validate 在进入来源选择前拒绝空数据集、未知数据集与重复数据集。
func (request ResolveContextRequest) Validate() error {
	if len(request.Datasets) == 0 {
		return fmt.Errorf("at least one dataset is required")
	}
	seen := make(map[DatasetType]struct{}, len(request.Datasets))
	for _, dataset := range request.Datasets {
		if !dataset.Valid() {
			return fmt.Errorf("unsupported dataset: %s", dataset)
		}
		if _, duplicated := seen[dataset]; duplicated {
			return fmt.Errorf("duplicated dataset: %s", dataset)
		}
		seen[dataset] = struct{}{}
	}
	if _, requestsSchedule := seen[DatasetSchedule]; requestsSchedule {
		if _, err := time.Parse("2006-01-02", strings.TrimSpace(request.ScheduleWeekContaining)); err != nil {
			return fmt.Errorf("schedule_week_containing must be YYYY-MM-DD when requesting schedule")
		}
	}
	switch request.Freshness {
	case FreshnessPreferRecent, FreshnessRequireFresh, FreshnessAllowStale:
		return nil
	default:
		return fmt.Errorf("unsupported freshness preference: %s", request.Freshness)
	}
}
