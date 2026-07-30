package services

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"shenliyuan/internal/dto"
)

// ComputeCompetitionRecordHash 使用规范化 JSON 计算记录摘要。
func ComputeCompetitionRecordHash(record dto.CompetitionCatalogRecord) (string, error) {
	normalized, err := normalizeCatalogRecord(record)
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(normalized)
	if err != nil {
		return "", fmt.Errorf("编码目录记录失败: %w", err)
	}
	var object map[string]any
	if err := json.Unmarshal(encoded, &object); err != nil {
		return "", fmt.Errorf("规范化目录记录失败: %w", err)
	}
	delete(object, "record_hash")
	canonical, err := json.Marshal(object)
	if err != nil {
		return "", fmt.Errorf("编码规范目录记录失败: %w", err)
	}
	sum := sha256.Sum256(canonical)
	return hex.EncodeToString(sum[:]), nil
}

// ComputeCompetitionPackageHash 固定按 competition_id 排序后计算包摘要。
func ComputeCompetitionPackageHash(
	document dto.CompetitionCatalogDocument,
	recordHashes map[string]string,
) (string, error) {
	type recordDigest struct {
		CompetitionID string `json:"competition_id"`
		RecordHash    string `json:"record_hash"`
	}
	records := make([]recordDigest, 0, len(document.Items))
	for _, record := range document.Items {
		id := strings.TrimSpace(record.CompetitionID)
		hash := strings.TrimSpace(recordHashes[id])
		if hash == "" {
			return "", fmt.Errorf("赛事 %s 缺少服务端记录摘要", id)
		}
		records = append(records, recordDigest{CompetitionID: id, RecordHash: hash})
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i].CompetitionID < records[j].CompetitionID
	})
	payload := struct {
		SchemaVersion         string         `json:"schema_version"`
		DatasetVersion        string         `json:"dataset_version"`
		PublishStatus         string         `json:"publish_status"`
		ProductionLoadAllowed bool           `json:"production_load_allowed"`
		ItemCount             int            `json:"item_count"`
		Records               []recordDigest `json:"records"`
	}{
		SchemaVersion:         strings.TrimSpace(document.SchemaVersion),
		DatasetVersion:        strings.TrimSpace(document.DatasetVersion),
		PublishStatus:         strings.TrimSpace(document.PublishStatus),
		ProductionLoadAllowed: document.ProductionLoadAllowed,
		ItemCount:             document.ItemCount,
		Records:               records,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("编码目录包失败: %w", err)
	}
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:]), nil
}

func normalizeCatalogRecord(
	record dto.CompetitionCatalogRecord,
) (dto.CompetitionCatalogRecord, error) {
	record.CompetitionID = strings.TrimSpace(record.CompetitionID)
	record.ParentCompetitionID = strings.TrimSpace(record.ParentCompetitionID)
	record.RecordHash = strings.TrimSpace(record.RecordHash)
	record.Title = strings.TrimSpace(record.Title)
	record.Subtitle = strings.TrimSpace(record.Subtitle)
	record.Summary = strings.TrimSpace(record.Summary)
	record.Description = strings.TrimSpace(record.Description)
	record.PrimaryCategorySlug = strings.TrimSpace(record.PrimaryCategorySlug)
	record.CompetitionLevel = strings.TrimSpace(record.CompetitionLevel)
	record.SchoolRecognitionStatus = strings.TrimSpace(record.SchoolRecognitionStatus)
	record.SchoolRecognitionGrade = strings.TrimSpace(record.SchoolRecognitionGrade)
	record.CompetitionRating = strings.ToUpper(strings.TrimSpace(record.CompetitionRating))
	record.Organizer = strings.TrimSpace(record.Organizer)
	record.HostUnit = strings.TrimSpace(record.HostUnit)
	record.TargetAudience = strings.TrimSpace(record.TargetAudience)
	record.ParticipationType = strings.TrimSpace(record.ParticipationType)
	record.RegistrationTimeText = strings.TrimSpace(record.RegistrationTimeText)
	record.EventTimeText = strings.TrimSpace(record.EventTimeText)
	record.TimePrecision = strings.TrimSpace(record.TimePrecision)
	record.TimeStatus = strings.TrimSpace(record.TimeStatus)
	record.TimeNote = strings.TrimSpace(record.TimeNote)
	record.Location = strings.TrimSpace(record.Location)
	record.OfficialURL = strings.TrimSpace(record.OfficialURL)
	record.NoticeURL = strings.TrimSpace(record.NoticeURL)
	record.SourceChannel = strings.TrimSpace(record.SourceChannel)
	record.SourceNote = strings.TrimSpace(record.SourceNote)
	record.Status = strings.TrimSpace(record.Status)
	record.ManualRatingReasonPublic = strings.TrimSpace(record.ManualRatingReasonPublic)
	record.MajorFitSummaryPublic = strings.TrimSpace(record.MajorFitSummaryPublic)
	record.EvidenceSummaryPublic = strings.TrimSpace(record.EvidenceSummaryPublic)
	record.EvidenceSubgrade = strings.TrimSpace(record.EvidenceSubgrade)
	record.RecommendationPermissionLevel = strings.TrimSpace(record.RecommendationPermissionLevel)
	record.AIMode = strings.TrimSpace(record.AIMode)
	record.Tags = normalizeCatalogStrings(record.Tags)
	record.EligibleEntryYears = normalizeCatalogStrings(record.EligibleEntryYears)
	record.EligibleColleges = normalizeCatalogStrings(record.EligibleColleges)
	record.EligibleMajors = normalizeCatalogStrings(record.EligibleMajors)
	record.RiskTags = normalizeCatalogStrings(record.RiskTags)
	record.BlockerCodes = normalizeCatalogStrings(record.BlockerCodes)
	var err error
	for name, value := range map[string]*string{
		"registration_start": &record.RegistrationStart,
		"registration_end":   &record.RegistrationEnd,
		"event_start":        &record.EventStart,
		"event_end":          &record.EventEnd,
	} {
		*value, err = normalizeCatalogDate(*value)
		if err != nil {
			return record, fmt.Errorf("%s: %w", name, err)
		}
	}
	return record, nil
}

func normalizeCatalogStrings(values []string) []string {
	if values == nil {
		return []string{}
	}
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{})
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func normalizeCatalogDate(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", nil
	}
	for _, layout := range []string{"2006-01-02", time.RFC3339} {
		if parsed, err := time.Parse(layout, value); err == nil {
			if layout == time.RFC3339 {
				return parsed.UTC().Format(time.RFC3339), nil
			}
			return parsed.Format("2006-01-02"), nil
		}
	}
	return "", fmt.Errorf("日期必须是 YYYY-MM-DD 或 RFC3339")
}
