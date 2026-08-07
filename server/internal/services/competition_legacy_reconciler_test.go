package services

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestLegacyCompetitionReconciliationDryRunKeepsLatestUpload(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	seedLegacyCompetitionUpload(t, db, "A", "B")
	seedLegacyCompetitionUpload(t, db, "A", "B")
	latest := seedLegacyCompetitionUpload(t, db, "A", "")
	if err := db.Delete(&latest[1]).Error; err != nil {
		t.Fatal(err)
	}

	report, err := NewLegacyCompetitionReconciler(db).Reconcile(
		context.Background(),
		LegacyCompetitionReconciliationOptions{
			ExpectedTotal: 6, ExpectedGroups: 2, ExpectedCopies: 3,
			CanonicalMinID: latest[0].ID, CanonicalMaxID: latest[1].ID,
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if report.Applied || report.TotalLegacyEvents != 6 || report.IdentityGroups != 2 ||
		report.ExactCopyGroups != 2 || report.CanonicalEvents != 2 ||
		report.SupersededEvents != 4 || report.SoftDeletedCanonicalEvents != 1 ||
		len(report.UnsafeGroups) != 0 {
		t.Fatalf("dry-run 报告错误: %+v", report)
	}
	var activeRows int64
	if err := db.Model(&models.CompetitionEvent{}).Count(&activeRows).Error; err != nil {
		t.Fatal(err)
	}
	if activeRows != 5 {
		t.Fatalf("dry-run 修改了软删除状态: active=%d want=5", activeRows)
	}
}

func TestLegacyCompetitionReconciliationApplyIsAuditedAndMigratesReferences(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	if err := db.AutoMigrate(
		&models.CompetitionLegacyDuplicateResolution{},
		&models.UserCompetitionCalendarItem{},
	); err != nil {
		t.Fatal(err)
	}
	first := seedLegacyCompetitionUpload(t, db, "A", "B")
	seedLegacyCompetitionUpload(t, db, "A", "B")
	latest := seedLegacyCompetitionUpload(t, db, "A", "")
	if err := db.Delete(&latest[1]).Error; err != nil {
		t.Fatal(err)
	}
	calendarItem := models.UserCompetitionCalendarItem{
		CalendarID: 1, UserID: 1, Title: first[0].Title,
		SourceType: "official", SourceEventID: &first[0].ID,
	}
	if err := db.Create(&calendarItem).Error; err != nil {
		t.Fatal(err)
	}
	options := LegacyCompetitionReconciliationOptions{
		Apply: true, ExpectedTotal: 6, ExpectedGroups: 2, ExpectedCopies: 3,
		CanonicalMinID: latest[0].ID, CanonicalMaxID: latest[1].ID,
		ActorUserID: 99,
	}
	if _, err := NewLegacyCompetitionReconciler(db).Reconcile(context.Background(), options); err == nil {
		t.Fatal("缺少备份确认时不应执行写入")
	}
	options.BackupConfirmed = true
	report, err := NewLegacyCompetitionReconciler(db).Reconcile(context.Background(), options)
	if err != nil {
		t.Fatal(err)
	}
	if !report.Applied || report.ReferencesMigrated != 1 {
		t.Fatalf("apply 报告错误: %+v", report)
	}
	var migrated models.UserCompetitionCalendarItem
	if err := db.First(&migrated, calendarItem.ID).Error; err != nil {
		t.Fatal(err)
	}
	if migrated.SourceEventID == nil || *migrated.SourceEventID != latest[0].ID {
		t.Fatalf("计划引用未迁移到最新记录: %+v", migrated)
	}
	var canonical []models.CompetitionEvent
	if err := db.Unscoped().Where("id IN ?", []uint{latest[0].ID, latest[1].ID}).Order("id").Find(&canonical).Error; err != nil {
		t.Fatal(err)
	}
	if len(canonical) != 2 || canonical[1].DeletedAt.Valid || canonical[1].CompetitionRating != "B" {
		t.Fatalf("最新 canonical 未恢复或未补齐评级: %+v", canonical)
	}
	for _, event := range canonical {
		if event.SearchDisplayAllowed || event.CandidatePoolAllowed || event.AIMode != "disabled" {
			t.Fatalf("canonical 身份记录权限未关闭: %+v", event)
		}
	}
	var superseded []models.CompetitionEvent
	if err := db.Unscoped().Where("id NOT IN ?", []uint{latest[0].ID, latest[1].ID}).Find(&superseded).Error; err != nil {
		t.Fatal(err)
	}
	if len(superseded) != 4 {
		t.Fatalf("superseded 数量=%d want=4", len(superseded))
	}
	for _, event := range superseded {
		if event.Status != "archived" || event.CandidatePoolAllowed || event.AIMode != "disabled" {
			t.Fatalf("旧副本未进入 superseded 状态: %+v", event)
		}
	}
	var auditCount int64
	if err := db.Model(&models.CompetitionLegacyDuplicateResolution{}).Count(&auditCount).Error; err != nil {
		t.Fatal(err)
	}
	if auditCount != 4 {
		t.Fatalf("归并审计数=%d want=4", auditCount)
	}
}

func TestLegacyCompetitionReconciliationRejectsUnknownReferenceSchema(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	if err := db.AutoMigrate(&models.CompetitionLegacyDuplicateResolution{}); err != nil {
		t.Fatal(err)
	}
	first := seedLegacyCompetitionUpload(t, db, "A", "B")
	seedLegacyCompetitionUpload(t, db, "A", "B")
	latest := seedLegacyCompetitionUpload(t, db, "A", "B")
	if err := db.Delete(&latest[1]).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec(`CREATE TABLE custom_competition_links (
		id integer PRIMARY KEY AUTOINCREMENT,
		competition_event_id integer NOT NULL
	)`).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("INSERT INTO custom_competition_links (competition_event_id) VALUES (?)", first[0].ID).Error; err != nil {
		t.Fatal(err)
	}

	_, err := NewLegacyCompetitionReconciler(db).Reconcile(context.Background(),
		LegacyCompetitionReconciliationOptions{
			Apply: true, BackupConfirmed: true,
			ExpectedTotal: 6, ExpectedGroups: 2, ExpectedCopies: 3,
			CanonicalMinID: latest[0].ID, CanonicalMaxID: latest[1].ID,
		},
	)
	if err == nil || !strings.Contains(err.Error(), "custom_competition_links.competition_event_id") {
		t.Fatalf("未知引用结构未阻断: %v", err)
	}
	var restored models.CompetitionEvent
	if err := db.Unscoped().First(&restored, latest[1].ID).Error; err != nil {
		t.Fatal(err)
	}
	if !restored.DeletedAt.Valid {
		t.Fatal("阻断后最新软删除记录被错误恢复")
	}
	var auditCount int64
	if err := db.Model(&models.CompetitionLegacyDuplicateResolution{}).Count(&auditCount).Error; err != nil {
		t.Fatal(err)
	}
	if auditCount != 0 {
		t.Fatalf("阻断后写入了审计记录: %d", auditCount)
	}
}

func TestLegacyCompetitionReconciliationMergesConflictingCalendarReferences(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	if err := db.AutoMigrate(
		&models.CompetitionLegacyDuplicateResolution{},
		&models.UserCompetitionCalendarItem{},
	); err != nil {
		t.Fatal(err)
	}
	if err := db.Exec(`CREATE UNIQUE INDEX ` + models.CompetitionOfficialUniqueIndex + `
		ON user_competition_calendar_items(user_id, source_event_id)
		WHERE deleted_at IS NULL AND source_type = 'official' AND source_event_id IS NOT NULL`).Error; err != nil {
		t.Fatal(err)
	}
	first := seedLegacyCompetitionUpload(t, db, "A", "B")
	second := seedLegacyCompetitionUpload(t, db, "A", "B")
	latest := seedLegacyCompetitionUpload(t, db, "A", "B")
	now := time.Now()
	items := []models.UserCompetitionCalendarItem{
		{CalendarID: 1, UserID: 8, Title: "普通", SourceType: "official", SourceEventID: &latest[0].ID, UpdatedAt: now},
		{CalendarID: 1, UserID: 8, Title: "置顶", SourceType: "official", SourceEventID: &second[0].ID, IsPinned: true, UpdatedAt: now.Add(-time.Hour)},
		{CalendarID: 1, UserID: 8, Title: "用户已修改", SourceType: "official", SourceEventID: &first[0].ID, IsCustomModified: true, UpdatedAt: now.Add(-2 * time.Hour)},
	}
	if err := db.Create(&items).Error; err != nil {
		t.Fatal(err)
	}
	_, err := NewLegacyCompetitionReconciler(db).Reconcile(context.Background(),
		LegacyCompetitionReconciliationOptions{
			Apply: true, BackupConfirmed: true,
			ExpectedTotal: 6, ExpectedGroups: 2, ExpectedCopies: 3,
			CanonicalMinID: latest[0].ID, CanonicalMaxID: latest[1].ID,
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	var active []models.UserCompetitionCalendarItem
	if err := db.Where("user_id = ?", 8).Find(&active).Error; err != nil {
		t.Fatal(err)
	}
	if len(active) != 1 || active[0].ID != items[2].ID ||
		active[0].SourceEventID == nil || *active[0].SourceEventID != latest[0].ID {
		t.Fatalf("计划引用保留优先级错误: %+v", active)
	}
	var all []models.UserCompetitionCalendarItem
	if err := db.Unscoped().Where("user_id = ?", 8).Find(&all).Error; err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Fatalf("计划引用被物理删除: %+v", all)
	}
	for _, item := range all {
		if item.SourceEventID == nil || *item.SourceEventID != latest[0].ID {
			t.Fatalf("历史计划引用未迁移: %+v", item)
		}
	}
}

func seedLegacyCompetitionUpload(
	t *testing.T,
	db *gorm.DB,
	firstRating, secondRating string,
) []models.CompetitionEvent {
	t.Helper()
	events := []models.CompetitionEvent{
		legacyReconciliationEvent("赛事甲", "A", firstRating),
		legacyReconciliationEvent("赛事乙", "B", secondRating),
	}
	if err := db.Create(&events).Error; err != nil {
		t.Fatal(err)
	}
	for index := range events {
		events[index].CompetitionID = fmt.Sprintf("LEGACY-%d", events[index].ID)
		if err := db.Model(&models.CompetitionEvent{}).Where("id = ?", events[index].ID).
			Update("competition_id", events[index].CompetitionID).Error; err != nil {
			t.Fatal(err)
		}
	}
	return events
}

func legacyReconciliationEvent(title, recommendationLevel, competitionRating string) models.CompetitionEvent {
	return models.CompetitionEvent{
		Title: title, DatasetVersion: "legacy", Status: "draft",
		CompetitionLevel: "省级", RecommendationLevel: recommendationLevel,
		CompetitionRating: competitionRating, TimePrecision: "unknown", TimeStatus: "pending",
		RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
	}
}
