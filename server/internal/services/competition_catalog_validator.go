package services

import (
	"fmt"
	"regexp"
	"strings"

	"shenliyuan/internal/dto"
)

var catalogHashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var catalogCompetitionIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{1,63}$`)

type CompetitionCatalogValidator struct{}

func NewCompetitionCatalogValidator() *CompetitionCatalogValidator {
	return &CompetitionCatalogValidator{}
}

func (v *CompetitionCatalogValidator) Validate(
	document dto.CompetitionCatalogDocument,
) dto.CompetitionCatalogValidationResult {
	result := dto.CompetitionCatalogValidationResult{
		Status: "passed", ComputedRecordHashes: map[string]string{},
		Issues: []dto.CompetitionCatalogValidationIssue{},
	}
	add := func(code, competitionID, field, message string) {
		result.Issues = append(result.Issues, dto.CompetitionCatalogValidationIssue{
			Level: "error", Code: code, CompetitionID: competitionID,
			Field: field, Message: message,
		})
		result.Status = "failed"
	}
	if strings.TrimSpace(document.SchemaVersion) != dto.CompetitionCatalogSchemaVersion {
		add("invalid_schema_version", "", "schema_version", "目录 Schema 版本必须为 "+dto.CompetitionCatalogSchemaVersion)
	}
	if strings.TrimSpace(document.DatasetVersion) == "" {
		add("missing_dataset_version", "", "dataset_version", "dataset_version 不能为空")
	}
	if document.ItemCount != len(document.Items) {
		add("item_count_mismatch", "", "item_count", "item_count 与实际记录数不一致")
	}
	if document.PublishStatus != "draft" && document.PublishStatus != "published" {
		add("invalid_publish_status", "", "publish_status", "publish_status 只能是 draft 或 published")
	}
	if !catalogHashPattern.MatchString(strings.TrimSpace(document.PackageHash)) {
		add("invalid_package_hash_format", "", "package_hash", "package_hash 必须是 64 位小写 SHA-256")
	}

	records := make(map[string]dto.CompetitionCatalogRecord, len(document.Items))
	for index, record := range document.Items {
		id := strings.TrimSpace(record.CompetitionID)
		if !catalogCompetitionIDPattern.MatchString(id) {
			add("invalid_competition_id", id, "competition_id", fmt.Sprintf("第 %d 条 competition_id 格式无效", index+1))
		}
		if _, exists := records[id]; exists {
			add("duplicate_competition_id", id, "competition_id", "competition_id 在目录包内重复")
			continue
		}
		records[id] = record
		v.validateRecord(record, add)
		computed, err := ComputeCompetitionRecordHash(record)
		if err != nil {
			add("record_normalization_failed", id, "record_hash", err.Error())
			continue
		}
		result.ComputedRecordHashes[id] = computed
		if !catalogHashPattern.MatchString(strings.TrimSpace(record.RecordHash)) {
			add("invalid_record_hash_format", id, "record_hash", "record_hash 必须是 64 位小写 SHA-256")
		} else if record.RecordHash != computed {
			add("record_hash_mismatch", id, "record_hash", "record_hash 与服务端复算结果不一致")
		}
	}
	v.validateParentGraph(records, add)
	computedPackageHash, err := ComputeCompetitionPackageHash(document, result.ComputedRecordHashes)
	if err != nil {
		add("package_hash_failed", "", "package_hash", err.Error())
	} else {
		result.ComputedPackageHash = computedPackageHash
		if document.PackageHash != computedPackageHash {
			add("package_hash_mismatch", "", "package_hash", "package_hash 与服务端复算结果不一致")
		}
	}
	return result
}

func (v *CompetitionCatalogValidator) validateRecord(
	record dto.CompetitionCatalogRecord,
	add func(string, string, string, string),
) {
	id := strings.TrimSpace(record.CompetitionID)
	if strings.TrimSpace(record.Title) == "" {
		add("missing_title", id, "title", "title 不能为空")
	}
	if record.Status != "published" && record.Status != "draft" && record.Status != "archived" {
		add("invalid_status", id, "status", "status 只能是 published、draft 或 archived")
	}
	if !containsCatalogEnum(record.TimePrecision, "exact", "month", "month_range", "quarter", "half_year", "season", "unknown") {
		add("invalid_time_precision", id, "time_precision", "time_precision 枚举无效")
	}
	if !containsCatalogEnum(record.TimeStatus, "confirmed", "estimated", "historical", "pending") {
		add("invalid_time_status", id, "time_status", "time_status 枚举无效")
	}
	if !containsCatalogEnum(record.RecommendationPermissionLevel, "low", "medium", "high") {
		add("invalid_permission_level", id, "recommendation_permission_level", "推荐权限级别枚举无效")
	}
	if !containsCatalogEnum(record.AIMode, "disabled", "candidate_explanation", "selected_comparison") {
		add("invalid_ai_mode", id, "ai_mode", "AI 模式枚举无效")
	}
	if !record.CandidatePoolAllowed {
		if record.PersonalizedRankingAllowed {
			add("ranking_without_candidate_pool", id, "personalized_ranking_allowed", "未进入候选池的赛事不能开放个性化排序")
		}
		if record.StrongRecommendationEligible {
			add("strong_without_candidate_pool", id, "strong_recommendation_eligible", "未进入候选池的赛事不能开放强推荐")
		}
	}
	if record.StrongRecommendationEligible {
		if record.RecommendationPermissionLevel != "high" {
			add("strong_requires_high_permission", id, "recommendation_permission_level", "强推荐必须使用 high 权限")
		}
		if !record.PersonalizedRankingAllowed {
			add("strong_requires_ranking", id, "personalized_ranking_allowed", "强推荐必须先开放个性化排序")
		}
		if len(record.BlockerCodes) > 0 {
			add("strong_has_blockers", id, "blocker_codes", "存在阻断码时不能开放强推荐")
		}
	}
	if len(record.BlockerCodes) > 0 && record.CandidatePoolAllowed {
		add("blocked_record_in_candidate_pool", id, "candidate_pool_allowed", "存在阻断码的赛事不能进入候选池")
	}
	if record.ParentCompetitionID == id && id != "" {
		add("self_parent", id, "parent_competition_id", "赛事不能引用自身为父赛事")
	}
	if record.TeamSizeMin < 0 || record.TeamSizeMax < 0 ||
		(record.TeamSizeMax > 0 && record.TeamSizeMin > record.TeamSizeMax) {
		add("invalid_team_size", id, "team_size_min", "团队人数范围无效")
	}
}

func (v *CompetitionCatalogValidator) validateParentGraph(
	records map[string]dto.CompetitionCatalogRecord,
	add func(string, string, string, string),
) {
	for id, record := range records {
		parent := strings.TrimSpace(record.ParentCompetitionID)
		if parent != "" {
			if _, exists := records[parent]; !exists {
				add("parent_not_found", id, "parent_competition_id", "父赛事 ID 不存在于同一目录包")
			}
		}
	}
	const (
		unvisited = iota
		visiting
		visited
	)
	state := make(map[string]int, len(records))
	var visit func(string)
	visit = func(id string) {
		if state[id] == visiting {
			add("parent_cycle", id, "parent_competition_id", "母子赛事引用形成循环")
			return
		}
		if state[id] == visited {
			return
		}
		state[id] = visiting
		parent := strings.TrimSpace(records[id].ParentCompetitionID)
		if _, exists := records[parent]; parent != "" && exists {
			visit(parent)
		}
		state[id] = visited
	}
	for id := range records {
		visit(id)
	}
}

func containsCatalogEnum(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}
