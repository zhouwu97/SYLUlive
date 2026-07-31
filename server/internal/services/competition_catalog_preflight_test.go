package services

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestCompetitionCatalogPreflightRequiresLegacyBaselineFirst(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), validCatalogDocument(t, "catalog-v1"), 1)
	if err != nil {
		t.Fatal(err)
	}
	result, err := importer.Preflight(context.Background(), catalog.ID, 1)
	if !errors.Is(err, ErrCatalogPreflightFailed) ||
		!containsCatalogBlocker(result.Report.BlockingIssues, "legacy_baseline_required_before_first_activation") {
		t.Fatalf("首次激活没有阻断普通目录: err=%v report=%+v", err, result.Report)
	}
}

func TestCompetitionCatalogIdentityBaselineCanBeFirstActivePackageWithZeroVisibility(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	if err := db.AutoMigrate(&models.CompetitionLegacyDuplicateResolution{}); err != nil {
		t.Fatal(err)
	}
	seedLegacyCompetitionUpload(t, db, "A", "B")
	seedLegacyCompetitionUpload(t, db, "A", "B")
	latest := seedLegacyCompetitionUpload(t, db, "A", "")
	if err := db.Delete(&latest[1]).Error; err != nil {
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
	document, _, err := NewCompetitionCatalogBaselineExporter(db).ExportIdentity(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), document, 7)
	if err != nil {
		t.Fatal(err)
	}
	preflight, err := importer.Preflight(context.Background(), catalog.ID, 7)
	if err != nil {
		t.Fatalf("身份基线首次预检失败: %v report=%+v", err, preflight.Report)
	}
	if preflight.Report.PublicItemCount != 0 || preflight.Report.CandidateItemCount != 0 ||
		!preflight.Report.CanActivate || preflight.Report.ExpectedActivePackageID != nil {
		t.Fatalf("身份基线预检报告错误: %+v", preflight.Report)
	}
	if err := importer.ActivateWithPreflight(context.Background(), catalog.ID, 7,
		CompetitionCatalogActivationRequest{
			PreflightToken: preflight.Token, ExpectedPackageHash: catalog.PackageHash,
		}); err != nil {
		t.Fatal(err)
	}
	var publicCount, candidateCount int64
	if err := db.Model(&models.CompetitionEvent{}).
		Where("catalog_package_id = ? AND status = ? AND search_display_allowed = ?", catalog.ID, "published", true).
		Count(&publicCount).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&models.CompetitionEvent{}).
		Where("catalog_package_id = ? AND candidate_pool_allowed = ?", catalog.ID, true).
		Count(&candidateCount).Error; err != nil {
		t.Fatal(err)
	}
	if publicCount != 0 || candidateCount != 0 {
		t.Fatalf("身份基线激活后权限泄漏: public=%d candidate=%d", publicCount, candidateCount)
	}
}

func TestCompetitionCatalogPreflightRejectsMissingCategory(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	seedActiveCatalogPackage(t, db, "a")
	importer := NewCompetitionCatalogImporter(db)
	document := validCatalogDocument(t, "catalog-missing-category")
	document.Items[0].PrimaryCategorySlug = "missing"
	refreshCatalogHashes(t, &document)
	catalog, _, err := importer.Import(context.Background(), document, 1)
	if err != nil {
		t.Fatal(err)
	}
	result, err := importer.Preflight(context.Background(), catalog.ID, 1)
	if !errors.Is(err, ErrCatalogPreflightFailed) ||
		!containsCatalogBlocker(result.Report.BlockingIssues, "missing_categories") {
		t.Fatalf("缺失分类没有阻断: err=%v report=%+v", err, result.Report)
	}
}

func TestCompetitionCatalogPreflightRejectsUnmappedReferencedActiveEvent(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	if err := db.AutoMigrate(&models.UserCompetitionCalendarItem{}); err != nil {
		t.Fatal(err)
	}
	requireCatalogCategory(t, db)
	active := seedActiveCatalogPackage(t, db, "a")
	legacy := candidateEvent("LEGACY-REFERENCED", "程序设计竞赛", 80, 1, nil, nil)
	legacy.CatalogPackageID = &active.ID
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	calendarItem := models.UserCompetitionCalendarItem{
		CalendarID: 1, UserID: 1, Title: legacy.Title,
		SourceType: "official", SourceEventID: &legacy.ID,
	}
	if err := db.Create(&calendarItem).Error; err != nil {
		t.Fatal(err)
	}
	award := models.UserCompetitionAward{
		UserID: 1, CompetitionEventID: &legacy.ID, CompetitionTitle: legacy.Title,
		CompetitionYear: 2026, AwardName: "一等奖", CompetitionStage: "national",
		Role: "member", SkillTags: datatypes.JSON(`[]`), EvidenceFileIDs: datatypes.JSON(`[]`),
	}
	if err := db.Create(&award).Error; err != nil {
		t.Fatal(err)
	}
	importer := NewCompetitionCatalogImporter(db)
	target, _, err := importer.Import(context.Background(), validCatalogDocument(t, "referenced-target"), 1)
	if err != nil {
		t.Fatal(err)
	}

	result, err := importer.Preflight(context.Background(), target.ID, 1)
	if !errors.Is(err, ErrCatalogPreflightFailed) ||
		!containsCatalogBlocker(result.Report.BlockingIssues, "unmapped_referenced_legacy_events") {
		t.Fatalf("未映射引用没有被阻断: err=%v report=%+v", err, result.Report)
	}
	if result.Report.UnmappedReferencedLegacyEventCount != 1 ||
		result.Report.UnmappedCalendarReferenceCount != 1 ||
		result.Report.UnmappedAwardReferenceCount != 1 {
		t.Fatalf("未映射引用统计错误: %+v", result.Report)
	}

	mapping := models.CompetitionCatalogLegacyMapping{
		PackageID: target.ID, CompetitionID: "NAT-006", LegacyEventID: legacy.ID,
		MatchType: "manual", Confidence: 1, ReviewStatus: "confirmed",
	}
	if err := db.Create(&mapping).Error; err != nil {
		t.Fatal(err)
	}
	result, err = importer.Preflight(context.Background(), target.ID, 1)
	if err != nil {
		t.Fatalf("确认映射后仍被阻断: err=%v report=%+v", err, result.Report)
	}
	if result.Report.UnmappedReferencedLegacyEventCount != 0 ||
		result.Report.CalendarReferenceCount != 1 || result.Report.AwardReferenceCount != 1 {
		t.Fatalf("确认映射后的引用统计错误: %+v", result.Report)
	}
}

func TestCompetitionCatalogActivationRejectsStaleOrUnauthorizedPreflight(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		mutate func(*CompetitionCatalogImporter, *CompetitionCatalogActivationRequest, *uint)
	}{
		{
			name: "expired",
			mutate: func(importer *CompetitionCatalogImporter, _ *CompetitionCatalogActivationRequest, _ *uint) {
				importer.now = func() time.Time { return time.Date(2026, 7, 30, 10, 11, 0, 0, time.UTC) }
			},
		},
		{
			name: "wrong actor",
			mutate: func(_ *CompetitionCatalogImporter, _ *CompetitionCatalogActivationRequest, actor *uint) {
				*actor = 2
			},
		},
		{
			name: "wrong hash",
			mutate: func(_ *CompetitionCatalogImporter, request *CompetitionCatalogActivationRequest, _ *uint) {
				request.ExpectedPackageHash = strings.Repeat("f", 64)
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			db := newCompetitionServiceTestDB(t)
			requireCatalogCategory(t, db)
			seedActiveCatalogPackage(t, db, "a")
			importer := NewCompetitionCatalogImporter(db)
			importer.now = func() time.Time { return time.Date(2026, 7, 30, 10, 0, 0, 0, time.UTC) }
			catalog, _, err := importer.Import(context.Background(), validCatalogDocument(t, "catalog-target"), 1)
			if err != nil {
				t.Fatal(err)
			}
			preflight, err := importer.Preflight(context.Background(), catalog.ID, 1)
			if err != nil {
				t.Fatal(err)
			}
			request := catalogActivationRequest(preflight, catalog.PackageHash)
			actor := uint(1)
			testCase.mutate(importer, &request, &actor)
			if err := importer.ActivateWithPreflight(context.Background(), catalog.ID, actor, request); !errors.Is(err, ErrCatalogPreflightRequired) {
				t.Fatalf("预检 token 应被拒绝: %v", err)
			}
		})
	}
}

func TestCompetitionCatalogActivationRejectsActivePackageCASChange(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	active := seedActiveCatalogPackage(t, db, "a")
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), validCatalogDocument(t, "catalog-cas"), 1)
	if err != nil {
		t.Fatal(err)
	}
	preflight, err := importer.Preflight(context.Background(), catalog.ID, 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&active).Update("is_active", false).Error; err != nil {
		t.Fatal(err)
	}
	seedActiveCatalogPackage(t, db, "b")
	request := catalogActivationRequest(preflight, catalog.PackageHash)
	if err := importer.ActivateWithPreflight(context.Background(), catalog.ID, 1, request); !errors.Is(err, ErrCatalogPreflightRequired) {
		t.Fatalf("活动包变化后仍接受预检 token: %v", err)
	}
}

func TestCompetitionCatalogPreflightTokenIsConsumedOnce(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	seedActiveCatalogPackage(t, db, "a")
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), validCatalogDocument(t, "catalog-once"), 1)
	if err != nil {
		t.Fatal(err)
	}
	preflight, err := importer.Preflight(context.Background(), catalog.ID, 1)
	if err != nil {
		t.Fatal(err)
	}
	request := catalogActivationRequest(preflight, catalog.PackageHash)
	if err := importer.ActivateWithPreflight(context.Background(), catalog.ID, 1, request); err != nil {
		t.Fatal(err)
	}
	if err := importer.ActivateWithPreflight(context.Background(), catalog.ID, 1, request); !errors.Is(err, ErrCatalogPreflightRequired) {
		t.Fatalf("同一 token 被重复消费: %v", err)
	}
	var snapshot models.CompetitionCatalogActivationSnapshot
	if err := db.Where("package_id = ?", catalog.ID).First(&snapshot).Error; err != nil {
		t.Fatal(err)
	}
	if snapshot.Status != "consumed" || snapshot.ConsumedAt == nil {
		t.Fatalf("激活快照未标记为已消费: %+v", snapshot)
	}
}

func TestLegacyBaselineActivationPreservesNonCatalogFields(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	sortDate := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	legacy := candidateEvent("LEGACY-BASELINE", "旧赛事", 80, 1, nil, nil)
	legacy.UndertakeUnit = "原承办单位"
	legacy.AttachmentURLs = datatypes.JSON(`["https://example.edu/notice.pdf"]`)
	legacy.SourceArticleID = "article-77"
	legacy.SortDate = &sortDate
	legacy.VerifiedBy = 9
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	document, _, err := NewCompetitionCatalogBaselineExporter(db).Export(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), document, 1)
	if err != nil {
		t.Fatal(err)
	}
	preflight, err := importer.Preflight(context.Background(), catalog.ID, 1)
	if err != nil {
		t.Fatal(err)
	}
	request := catalogActivationRequest(preflight, catalog.PackageHash)
	if err := importer.ActivateWithPreflight(context.Background(), catalog.ID, 1, request); err != nil {
		t.Fatal(err)
	}
	var persisted models.CompetitionEvent
	if err := db.First(&persisted, legacy.ID).Error; err != nil {
		t.Fatal(err)
	}
	if persisted.UndertakeUnit != legacy.UndertakeUnit ||
		string(persisted.AttachmentURLs) != string(legacy.AttachmentURLs) ||
		persisted.SourceArticleID != legacy.SourceArticleID || persisted.SortDate == nil ||
		!persisted.SortDate.Equal(sortDate) || persisted.VerifiedBy != legacy.VerifiedBy {
		t.Fatalf("首次基线激活覆盖了旧赛事扩展字段: %+v", persisted)
	}
	if persisted.CatalogPackageID == nil || *persisted.CatalogPackageID != catalog.ID ||
		persisted.AIMode != "disabled" {
		t.Fatalf("首次基线未绑定治理字段: %+v", persisted)
	}
}

func TestLegacyBaselinePreflightRejectsChangedSourceEvent(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	legacy := candidateEvent("LEGACY-STALE", "导出时标题", 80, 1, nil, nil)
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	document, _, err := NewCompetitionCatalogBaselineExporter(db).Export(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), document, 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Model(&legacy).Update("title", "导出后标题已变化").Error; err != nil {
		t.Fatal(err)
	}
	result, err := importer.Preflight(context.Background(), catalog.ID, 1)
	if !errors.Is(err, ErrCatalogPreflightFailed) ||
		!containsCatalogBlocker(result.Report.BlockingIssues, "legacy_baseline_snapshot_changed") {
		t.Fatalf("过期基线没有被阻断: err=%v report=%+v", err, result.Report)
	}
}

func seedActiveCatalogPackage(t *testing.T, db *gorm.DB, hashCharacter string) models.CompetitionCatalogPackage {
	t.Helper()
	now := time.Now()
	catalog := models.CompetitionCatalogPackage{
		SchemaVersion: "sylulive-competition-catalog/2.2", DatasetVersion: "active-" + hashCharacter,
		Revision: 1, PackageHash: strings.Repeat(hashCharacter, 64), LifecycleStatus: "active",
		PublishStatus: "published", ProductionLoadAllowed: true, ItemCount: 0,
		ValidationStatus: "passed", ValidationResult: datatypes.JSON(`{}`), Payload: datatypes.JSON(`{}`),
		ImportedBy: 1, ImportedAt: now, ActivatedAt: &now, IsActive: true,
	}
	if err := db.Create(&catalog).Error; err != nil {
		t.Fatal(err)
	}
	return catalog
}

func catalogActivationRequest(
	preflight CompetitionCatalogPreflightResult,
	packageHash string,
) CompetitionCatalogActivationRequest {
	return CompetitionCatalogActivationRequest{
		PreflightToken: preflight.Token, ExpectedActivePackageID: preflight.Report.ExpectedActivePackageID,
		ExpectedPackageHash: packageHash,
	}
}

func containsCatalogBlocker(blockers []string, expected string) bool {
	for _, blocker := range blockers {
		if blocker == expected {
			return true
		}
	}
	return false
}
