package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/models"
)

type LegacyCompetitionReconciliationOptions struct {
	Apply           bool `json:"apply"`
	BackupConfirmed bool `json:"backup_confirmed"`
	ExpectedTotal   int  `json:"expected_total"`
	ExpectedGroups  int  `json:"expected_groups"`
	ExpectedCopies  int  `json:"expected_copies"`
	CanonicalMinID  uint `json:"canonical_min_id"`
	CanonicalMaxID  uint `json:"canonical_max_id"`
	ActorUserID     uint `json:"actor_user_id"`
}

type LegacyCompetitionUnsafeGroup struct {
	IdentityHash string `json:"identity_hash"`
	EventIDs     []uint `json:"event_ids"`
	Reason       string `json:"reason"`
}

type LegacyCompetitionReconciliationReport struct {
	Applied                    bool                           `json:"applied"`
	TotalLegacyEvents          int                            `json:"total_legacy_events"`
	IdentityGroups             int                            `json:"identity_groups"`
	ExactCopyGroups            int                            `json:"exact_copy_groups"`
	CanonicalEvents            int                            `json:"canonical_events"`
	SupersededEvents           int                            `json:"superseded_events"`
	SoftDeletedCanonicalEvents int                            `json:"soft_deleted_canonical_events"`
	ReferencesMigrated         int64                          `json:"references_migrated"`
	UnsafeGroups               []LegacyCompetitionUnsafeGroup `json:"unsafe_groups"`
	UnsafeReferenceSchemas     []string                       `json:"unsafe_reference_schemas"`
}

type legacyCompetitionGroup struct {
	IdentityHash string
	Events       []models.CompetitionEvent
	Canonical    models.CompetitionEvent
}

type LegacyCompetitionReconciler struct {
	db *gorm.DB
}

func NewLegacyCompetitionReconciler(db *gorm.DB) *LegacyCompetitionReconciler {
	return &LegacyCompetitionReconciler{db: db}
}

func (r *LegacyCompetitionReconciler) Reconcile(
	ctx context.Context,
	options LegacyCompetitionReconciliationOptions,
) (LegacyCompetitionReconciliationReport, error) {
	if r == nil || r.db == nil {
		return LegacyCompetitionReconciliationReport{}, fmt.Errorf("database is nil")
	}
	groups, report, err := r.inspect(ctx, r.db, options)
	if err != nil {
		return report, err
	}
	if !options.Apply {
		return report, nil
	}
	if !options.BackupConfirmed {
		return report, fmt.Errorf("写入操作必须同时确认数据库备份")
	}
	if len(report.UnsafeGroups) > 0 || len(report.UnsafeReferenceSchemas) > 0 {
		return report, fmt.Errorf(
			"存在不安全分组或未知引用结构，拒绝归并: %s",
			strings.Join(report.UnsafeReferenceSchemas, ","),
		)
	}
	err = r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		lockedGroups, current, err := r.inspect(ctx, tx, options)
		if err != nil {
			return err
		}
		if len(current.UnsafeGroups) > 0 || len(current.UnsafeReferenceSchemas) > 0 ||
			len(lockedGroups) != len(groups) {
			return fmt.Errorf("归并输入在执行前发生变化")
		}
		if !tx.Migrator().HasTable(&models.CompetitionLegacyDuplicateResolution{}) {
			return fmt.Errorf("缺少旧赛事归并审计表")
		}
		now := time.Now()
		for _, group := range lockedGroups {
			duplicateIDs := make([]uint, 0, len(group.Events)-1)
			groupEventIDs := make([]uint, 0, len(group.Events))
			for _, event := range group.Events {
				groupEventIDs = append(groupEventIDs, event.ID)
				if event.ID != group.Canonical.ID {
					duplicateIDs = append(duplicateIDs, event.ID)
				}
			}
			calendarMigrated, err := mergeConflictingLegacyCalendarReferences(
				tx, groupEventIDs, group.Canonical.ID,
			)
			if err != nil {
				return err
			}
			report.ReferencesMigrated += calendarMigrated
			migrated, err := migrateLegacyCompetitionReferences(tx, duplicateIDs, group.Canonical.ID)
			if err != nil {
				return err
			}
			report.ReferencesMigrated += migrated
			if err := tx.Unscoped().Model(&models.CompetitionEvent{}).
				Where("id = ?", group.Canonical.ID).Updates(map[string]any{
				"competition_rating": legacyCompetitionRating(group.Canonical),
				"deleted_at":         nil, "search_display_allowed": false,
				"candidate_pool_allowed": false, "personalized_ranking_allowed": false,
				"strong_recommendation_eligible":  false,
				"recommendation_permission_level": "blocked", "ai_mode": "disabled",
			}).Error; err != nil {
				return err
			}
			if err := tx.Unscoped().Model(&models.CompetitionEvent{}).
				Where("id IN ?", duplicateIDs).Updates(map[string]any{
				"status": "archived", "archived_at": now,
				"search_display_allowed": false, "candidate_pool_allowed": false,
				"personalized_ranking_allowed": false, "strong_recommendation_eligible": false,
				"recommendation_permission_level": "blocked", "ai_mode": "disabled",
			}).Error; err != nil {
				return err
			}
			for _, event := range group.Events {
				if event.ID == group.Canonical.ID {
					continue
				}
				resolution := models.CompetitionLegacyDuplicateResolution{
					IdentityHash: group.IdentityHash, CanonicalEventID: group.Canonical.ID,
					DuplicateEventID: event.ID, Reason: "superseded_failed_upload",
					DuplicatePreviousStatus: event.Status, DuplicateWasDeleted: event.DeletedAt.Valid,
					CanonicalWasDeleted: group.Canonical.DeletedAt.Valid,
					ResolvedBy:          options.ActorUserID, ResolvedAt: now,
				}
				if err := tx.Clauses(clause.OnConflict{
					Columns: []clause.Column{{Name: "duplicate_event_id"}},
					DoUpdates: clause.AssignmentColumns([]string{
						"identity_hash", "canonical_event_id", "reason", "resolved_by", "resolved_at",
					}),
				}).Create(&resolution).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return report, err
	}
	report.Applied = true
	return report, nil
}

func mergeConflictingLegacyCalendarReferences(
	tx *gorm.DB,
	eventIDs []uint,
	canonicalID uint,
) (int64, error) {
	if !tx.Migrator().HasTable(&models.UserCompetitionCalendarItem{}) {
		return 0, nil
	}
	var items []models.UserCompetitionCalendarItem
	if err := tx.Where("source_type = ? AND source_event_id IN ?", "official", eventIDs).
		Find(&items).Error; err != nil {
		return 0, err
	}
	groups := make(map[uint][]models.UserCompetitionCalendarItem)
	for _, item := range items {
		groups[item.UserID] = append(groups[item.UserID], item)
	}
	var migrated int64
	for _, userItems := range groups {
		sort.SliceStable(userItems, func(left, right int) bool {
			return legacyCalendarItemPreferred(userItems[left], userItems[right])
		})
		winner := userItems[0]
		if len(userItems) > 1 {
			loserIDs := make([]uint, 0, len(userItems)-1)
			for _, loser := range userItems[1:] {
				loserIDs = append(loserIDs, loser.ID)
			}
			if err := tx.Where("id IN ?", loserIDs).
				Delete(&models.UserCompetitionCalendarItem{}).Error; err != nil {
				return migrated, err
			}
		}
		if winner.SourceEventID == nil || *winner.SourceEventID != canonicalID {
			result := tx.Model(&models.UserCompetitionCalendarItem{}).
				Where("id = ?", winner.ID).Update("source_event_id", canonicalID)
			if result.Error != nil {
				return migrated, result.Error
			}
			migrated += result.RowsAffected
		}
	}
	return migrated, nil
}

func legacyCalendarItemPreferred(
	left models.UserCompetitionCalendarItem,
	right models.UserCompetitionCalendarItem,
) bool {
	if left.IsCustomModified != right.IsCustomModified {
		return left.IsCustomModified
	}
	if left.IsPinned != right.IsPinned {
		return left.IsPinned
	}
	planRank := map[string]int{
		"watching": 1, "preparing": 2, "registered": 3,
		"submitted": 4, "finished": 5, "archived": 6,
	}
	if planRank[left.PlanStatus] != planRank[right.PlanStatus] {
		return planRank[left.PlanStatus] > planRank[right.PlanStatus]
	}
	if !left.UpdatedAt.Equal(right.UpdatedAt) {
		return left.UpdatedAt.After(right.UpdatedAt)
	}
	return left.ID < right.ID
}

type legacyCompetitionReference struct {
	Table  string
	Column string
}

var legacyCompetitionReferences = []legacyCompetitionReference{
	{Table: "competition_event_attachments", Column: "event_id"},
	{Table: "competition_recommendation_snapshots", Column: "event_id"},
	{Table: "user_competition_calendar_items", Column: "source_event_id"},
	{Table: "user_competition_awards", Column: "competition_event_id"},
	{Table: "ai_action_drafts", Column: "competition_event_id"},
	{Table: "competition_catalog_legacy_mappings", Column: "legacy_event_id"},
	{Table: "competition_events", Column: "parent_event_id"},
}

func migrateLegacyCompetitionReferences(tx *gorm.DB, duplicateIDs []uint, canonicalID uint) (int64, error) {
	var migrated int64
	for _, reference := range legacyCompetitionReferences {
		if !tx.Migrator().HasTable(reference.Table) || !tx.Migrator().HasColumn(reference.Table, reference.Column) {
			continue
		}
		result := tx.Unscoped().Table(reference.Table).
			Where(reference.Column+" IN ?", duplicateIDs).
			Update(reference.Column, canonicalID)
		if result.Error != nil {
			return migrated, fmt.Errorf("迁移引用 %s.%s 失败: %w", reference.Table, reference.Column, result.Error)
		}
		migrated += result.RowsAffected
	}
	return migrated, nil
}

func (r *LegacyCompetitionReconciler) inspect(
	ctx context.Context,
	db *gorm.DB,
	options LegacyCompetitionReconciliationOptions,
) ([]legacyCompetitionGroup, LegacyCompetitionReconciliationReport, error) {
	var events []models.CompetitionEvent
	if err := db.WithContext(ctx).Unscoped().
		Where("catalog_package_id IS NULL").
		Where("dataset_version = '' OR dataset_version = 'legacy'").
		Order("id ASC").Find(&events).Error; err != nil {
		return nil, LegacyCompetitionReconciliationReport{}, err
	}
	report := LegacyCompetitionReconciliationReport{
		TotalLegacyEvents: len(events), UnsafeGroups: []LegacyCompetitionUnsafeGroup{},
		UnsafeReferenceSchemas: []string{},
	}
	unsafeReferences, err := inspectUnknownLegacyCompetitionReferences(db)
	if err != nil {
		return nil, report, err
	}
	report.UnsafeReferenceSchemas = unsafeReferences
	grouped := make(map[string][]models.CompetitionEvent)
	for index := range events {
		hash, err := legacyCompetitionIdentityHash(events[index])
		if err != nil {
			return nil, report, err
		}
		grouped[hash] = append(grouped[hash], events[index])
	}
	report.IdentityGroups = len(grouped)
	groups := make([]legacyCompetitionGroup, 0, len(grouped))
	for hash, candidates := range grouped {
		group := legacyCompetitionGroup{IdentityHash: hash, Events: candidates}
		canonicalCount := 0
		for _, event := range candidates {
			if event.ID >= options.CanonicalMinID && event.ID <= options.CanonicalMaxID {
				group.Canonical = event
				canonicalCount++
			}
		}
		reason := ""
		if len(candidates) != options.ExpectedCopies {
			reason = fmt.Sprintf("副本数=%d want=%d", len(candidates), options.ExpectedCopies)
		} else if canonicalCount != 1 {
			reason = fmt.Sprintf("canonical 范围命中=%d want=1", canonicalCount)
		}
		if reason != "" {
			ids := make([]uint, 0, len(candidates))
			for _, event := range candidates {
				ids = append(ids, event.ID)
			}
			report.UnsafeGroups = append(report.UnsafeGroups, LegacyCompetitionUnsafeGroup{
				IdentityHash: hash, EventIDs: ids, Reason: reason,
			})
			continue
		}
		report.ExactCopyGroups++
		report.CanonicalEvents++
		report.SupersededEvents += len(candidates) - 1
		if group.Canonical.DeletedAt.Valid {
			report.SoftDeletedCanonicalEvents++
		}
		groups = append(groups, group)
	}
	if options.ExpectedTotal > 0 && report.TotalLegacyEvents != options.ExpectedTotal {
		report.UnsafeGroups = append(report.UnsafeGroups, LegacyCompetitionUnsafeGroup{
			Reason: fmt.Sprintf("旧赛事总数=%d want=%d", report.TotalLegacyEvents, options.ExpectedTotal),
		})
	}
	if options.ExpectedGroups > 0 && report.IdentityGroups != options.ExpectedGroups {
		report.UnsafeGroups = append(report.UnsafeGroups, LegacyCompetitionUnsafeGroup{
			Reason: fmt.Sprintf("身份组数=%d want=%d", report.IdentityGroups, options.ExpectedGroups),
		})
	}
	return groups, report, nil
}

func inspectUnknownLegacyCompetitionReferences(db *gorm.DB) ([]string, error) {
	tables, err := db.Migrator().GetTables()
	if err != nil {
		return nil, err
	}
	allowed := make(map[string]struct{}, len(legacyCompetitionReferences))
	for _, reference := range legacyCompetitionReferences {
		allowed[reference.Table+"."+reference.Column] = struct{}{}
	}
	unknown := make([]string, 0)
	for _, table := range tables {
		columns, err := db.Migrator().ColumnTypes(table)
		if err != nil {
			return nil, err
		}
		for _, column := range columns {
			name := strings.ToLower(column.Name())
			candidate := name == "competition_event_id" || name == "source_event_id" ||
				name == "legacy_event_id" || name == "parent_event_id" ||
				(name == "event_id" && strings.Contains(strings.ToLower(table), "competition"))
			if !candidate {
				continue
			}
			identity := table + "." + name
			if _, known := allowed[identity]; !known {
				unknown = append(unknown, identity)
			}
		}
	}
	sort.Strings(unknown)
	return unknown, nil
}

func legacyCompetitionIdentityHash(event models.CompetitionEvent) (string, error) {
	// 身份字段覆盖赛事事实，排除导入批次、状态、权限、审计时间和数据库标识。
	identity := struct {
		Title, Subtitle, Summary, Description                          string
		PrimaryCategoryID                                              uint
		Tags, EligibleEntryYears, EligibleColleges, EligibleMajors     json.RawMessage
		CompetitionLevel, SchoolStatus, SchoolGrade, CompetitionRating string
		ImportanceScore                                                int
		RecommendationReason                                           string
		IsFeatured, IsVerified                                         bool
		Organizer, HostUnit, UndertakeUnit, TargetAudience             string
		ParticipationType                                              string
		TeamSizeMin, TeamSizeMax                                       int
		RegistrationStart, RegistrationEnd, EventStart, EventEnd       string
		RegistrationTimeText, EventTimeText, TimePrecision, TimeStatus string
		TimeNote                                                       string
		SortMonth                                                      int
		SortDate                                                       string
		Location, OfficialURL, NoticeURL                               string
		IsOnline                                                       bool
		AttachmentURLs                                                 json.RawMessage
		SourceChannel, SourceNote, SourceArticleID                     string
		ManualRatingReason, MajorFitSummary, EvidenceSummary           string
		EvidenceSubgrade                                               string
		RiskTags, BlockerCodes                                         json.RawMessage
		CatalogOrder                                                   int
		ParentCompetitionID                                            string
	}{
		Title: normalizeLegacyIdentityText(event.Title), Subtitle: strings.TrimSpace(event.Subtitle),
		Summary: strings.TrimSpace(event.Summary), Description: strings.TrimSpace(event.Description),
		PrimaryCategoryID: event.PrimaryCategoryID, Tags: normalizedLegacyJSON(event.Tags),
		EligibleEntryYears: normalizedLegacyJSON(event.EligibleEntryYears),
		EligibleColleges:   normalizedLegacyJSON(event.EligibleColleges),
		EligibleMajors:     normalizedLegacyJSON(event.EligibleMajors),
		CompetitionLevel:   strings.TrimSpace(event.CompetitionLevel),
		SchoolStatus:       strings.TrimSpace(event.SchoolRecognitionStatus),
		SchoolGrade:        strings.TrimSpace(event.SchoolRecognitionGrade),
		CompetitionRating:  legacyCompetitionRating(event), ImportanceScore: event.ImportanceScore,
		RecommendationReason: strings.TrimSpace(event.RecommendationReason),
		IsFeatured:           event.IsFeatured, IsVerified: event.IsVerified,
		Organizer: strings.TrimSpace(event.Organizer), HostUnit: strings.TrimSpace(event.HostUnit),
		UndertakeUnit: strings.TrimSpace(event.UndertakeUnit), TargetAudience: strings.TrimSpace(event.TargetAudience),
		ParticipationType: strings.TrimSpace(event.ParticipationType),
		TeamSizeMin:       event.TeamSizeMin, TeamSizeMax: event.TeamSizeMax,
		RegistrationStart: legacyIdentityTime(event.RegistrationStart),
		RegistrationEnd:   legacyIdentityTime(event.RegistrationEnd),
		EventStart:        legacyIdentityTime(event.EventStart), EventEnd: legacyIdentityTime(event.EventEnd),
		RegistrationTimeText: strings.TrimSpace(event.RegistrationTimeText),
		EventTimeText:        strings.TrimSpace(event.EventTimeText), TimePrecision: strings.TrimSpace(event.TimePrecision),
		TimeStatus: strings.TrimSpace(event.TimeStatus), TimeNote: strings.TrimSpace(event.TimeNote),
		SortMonth: event.SortMonth, SortDate: legacyIdentityTime(event.SortDate),
		Location: strings.TrimSpace(event.Location), IsOnline: event.IsOnline,
		OfficialURL: strings.TrimSpace(event.OfficialURL), NoticeURL: strings.TrimSpace(event.NoticeURL),
		AttachmentURLs: normalizedLegacyJSON(event.AttachmentURLs),
		SourceChannel:  strings.TrimSpace(event.SourceChannel), SourceNote: strings.TrimSpace(event.SourceNote),
		SourceArticleID:    strings.TrimSpace(event.SourceArticleID),
		ManualRatingReason: strings.TrimSpace(event.ManualRatingReasonPublic),
		MajorFitSummary:    strings.TrimSpace(event.MajorFitSummaryPublic),
		EvidenceSummary:    strings.TrimSpace(event.EvidenceSummaryPublic),
		EvidenceSubgrade:   strings.TrimSpace(event.EvidenceSubgrade),
		RiskTags:           normalizedLegacyJSON(event.RiskTags), BlockerCodes: normalizedLegacyJSON(event.BlockerCodes),
		CatalogOrder: event.CatalogOrder, ParentCompetitionID: strings.TrimSpace(event.ParentCompetitionID),
	}
	encoded, err := json.Marshal(identity)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:]), nil
}

func normalizeLegacyIdentityText(value string) string {
	return strings.Join(strings.Fields(strings.TrimSpace(value)), " ")
}

func normalizedLegacyJSON(value []byte) json.RawMessage {
	if len(value) == 0 || string(value) == "null" {
		return json.RawMessage("[]")
	}
	var decoded any
	if json.Unmarshal(value, &decoded) != nil {
		return json.RawMessage(value)
	}
	encoded, _ := json.Marshal(decoded)
	return encoded
}

func legacyCompetitionRating(event models.CompetitionEvent) string {
	if rating := strings.TrimSpace(event.CompetitionRating); rating != "" {
		return rating
	}
	return strings.TrimSpace(event.RecommendationLevel)
}

func legacyIdentityTime(value *time.Time) string {
	if value == nil {
		return ""
	}
	return value.UTC().Format(time.RFC3339Nano)
}
