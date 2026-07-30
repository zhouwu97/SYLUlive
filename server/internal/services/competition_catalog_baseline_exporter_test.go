package services

import (
	"context"
	"errors"
	"testing"
	"time"

	"gorm.io/datatypes"

	"shenliyuan/internal/models"
)

func TestCompetitionCatalogBaselineExportIsConservativeAndValid(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	registrationEnd := time.Date(2026, 9, 20, 8, 30, 0, 0, time.FixedZone("CST", 8*60*60))
	events := []models.CompetitionEvent{
		{
			CompetitionID: "LEGACY-10", DatasetVersion: "legacy", Title: "旧程序设计竞赛",
			PrimaryCategoryID: category.ID, Tags: datatypes.JSON(`["算法","C++"]`),
			EligibleEntryYears: datatypes.JSON(`[]`), EligibleColleges: datatypes.JSON(`[]`),
			EligibleMajors: datatypes.JSON(`["计算机科学与技术"]`),
			RiskTags:       datatypes.JSON(`["long_term_training"]`), BlockerCodes: datatypes.JSON(`[]`),
			CompetitionLevel: "国家级", SchoolRecognitionStatus: "recognized",
			RecommendationLevel: "B+", RegistrationEnd: &registrationEnd,
			TimePrecision: "exact", TimeStatus: "confirmed", Status: "published",
			SearchDisplayAllowed: false, CandidatePoolAllowed: false,
			PersonalizedRankingAllowed: true, StrongRecommendationEligible: true,
			RecommendationPermissionLevel: "high", AIMode: "candidate_explanation",
		},
		{
			CompetitionID: "LEGACY-11", DatasetVersion: "legacy", Title: "旧通用竞赛",
			Tags: datatypes.JSON(`[]`), EligibleEntryYears: datatypes.JSON(`[]`),
			EligibleColleges: datatypes.JSON(`[]`), EligibleMajors: datatypes.JSON(`[]`),
			RiskTags: datatypes.JSON(`[]`), BlockerCodes: datatypes.JSON(`[]`),
			TimePrecision: "unknown", TimeStatus: "pending", Status: "published",
		},
	}
	if err := db.Create(&events).Error; err != nil {
		t.Fatal(err)
	}

	document, validation, err := NewCompetitionCatalogBaselineExporter(db).
		Export(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if validation.Status != "passed" || document.PackageHash != validation.ComputedPackageHash {
		t.Fatalf("基线校验失败: document=%+v validation=%+v", document, validation)
	}
	if document.DatasetVersion != LegacyCompetitionBaselineDataset ||
		document.PublishStatus != "published" || !document.ProductionLoadAllowed ||
		document.ItemCount != 2 || len(document.Items) != 2 {
		t.Fatalf("基线包元数据错误: %+v", document)
	}
	first := document.Items[0]
	if first.CompetitionID != "LEGACY-10" || first.PrimaryCategorySlug != "computer" ||
		first.CompetitionRating != "B+" || first.RegistrationEnd != "2026-09-20T00:30:00Z" {
		t.Fatalf("旧赛事事实投影错误: %+v", first)
	}
	if !first.SearchDisplayAllowed || !first.CandidatePoolAllowed ||
		first.PersonalizedRankingAllowed || first.StrongRecommendationEligible ||
		first.RecommendationPermissionLevel != "low" || first.AIMode != "disabled" {
		t.Fatalf("旧目录基线权限不够保守或未保持兼容展示: %+v", first)
	}
	if len(first.RecordHash) != 64 || first.RecordHash != validation.ComputedRecordHashes[first.CompetitionID] {
		t.Fatalf("记录摘要错误: %+v", first)
	}
}

func TestCompetitionCatalogBaselineExportRequiresFirstActivationState(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	exporter := NewCompetitionCatalogBaselineExporter(db)
	if _, _, err := exporter.Export(context.Background()); !errors.Is(err, ErrCatalogBaselineEmpty) {
		t.Fatalf("空旧目录应拒绝导出: %v", err)
	}

	active := models.CompetitionCatalogPackage{
		SchemaVersion: "test", DatasetVersion: "active", Revision: 1,
		PackageHash: "a", LifecycleStatus: "active", PublishStatus: "published",
		ProductionLoadAllowed: true, ValidationStatus: "passed",
		ValidationResult: datatypes.JSON(`{}`), Payload: datatypes.JSON(`{}`),
		ImportedBy: 1, ImportedAt: time.Now(), IsActive: true,
	}
	if err := db.Create(&active).Error; err != nil {
		t.Fatal(err)
	}
	if _, _, err := exporter.Export(context.Background()); !errors.Is(err, ErrCatalogBaselineAlreadyExists) {
		t.Fatalf("已有活动包应拒绝基线导出: %v", err)
	}
}
