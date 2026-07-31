package services

import (
	"context"
	"errors"
	"testing"

	"shenliyuan/internal/models"
)

func TestCompetitionCatalogLegacyMapperSuggestsExactTitleMatch(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	active := seedActiveCatalogPackage(t, db, "a")
	legacy := candidateEvent("LEGACY-10", "程序设计竞赛", 80, 1, nil, nil)
	legacy.CatalogPackageID = &active.ID
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	target, _, err := NewCompetitionCatalogImporter(db).
		Import(context.Background(), validCatalogDocument(t, "mapping-target"), 1)
	if err != nil {
		t.Fatal(err)
	}

	result, err := NewCompetitionCatalogLegacyMapper(db).Suggest(context.Background(), target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if result.Created != 1 || result.ConflictCount != 0 || result.Unmatched != 0 {
		t.Fatalf("映射建议统计异常: %+v", result)
	}
	var mapping models.CompetitionCatalogLegacyMapping
	if err := db.Where("package_id = ? AND competition_id = ?", target.ID, "NAT-006").
		First(&mapping).Error; err != nil {
		t.Fatal(err)
	}
	if mapping.LegacyEventID != legacy.ID || mapping.MatchType != "title_exact" ||
		mapping.Confidence != 1 || mapping.ReviewStatus != "suggested" {
		t.Fatalf("映射建议内容异常: %+v", mapping)
	}
}

func TestCompetitionCatalogLegacyMapperRejectsConfirmedOneToManyConflict(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	active := seedActiveCatalogPackage(t, db, "a")
	legacy := candidateEvent("LEGACY-20", "程序设计竞赛", 80, 1, nil, nil)
	legacy.CatalogPackageID = &active.ID
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	document := validCatalogDocument(t, "mapping-conflict")
	second := document.Items[0]
	second.CompetitionID = "NAT-007"
	second.Title = "程序设计竞赛赛道"
	document.Items = append(document.Items, second)
	document.ItemCount = len(document.Items)
	refreshCatalogHashes(t, &document)
	target, _, err := NewCompetitionCatalogImporter(db).Import(context.Background(), document, 1)
	if err != nil {
		t.Fatal(err)
	}
	mappings := []models.CompetitionCatalogLegacyMapping{
		{PackageID: target.ID, CompetitionID: "NAT-006", LegacyEventID: legacy.ID, MatchType: "manual", Confidence: 1, ReviewStatus: "suggested"},
		{PackageID: target.ID, CompetitionID: "NAT-007", LegacyEventID: legacy.ID, MatchType: "manual", Confidence: 1, ReviewStatus: "suggested"},
	}
	if err := db.Create(&mappings).Error; err != nil {
		t.Fatal(err)
	}
	mapper := NewCompetitionCatalogLegacyMapper(db)
	if _, err := mapper.Review(context.Background(), target.ID, mappings[0].ID, 7,
		CompetitionCatalogLegacyMappingReviewRequest{ReviewStatus: "confirmed"}); err != nil {
		t.Fatal(err)
	}
	if _, err := mapper.Review(context.Background(), target.ID, mappings[1].ID, 7,
		CompetitionCatalogLegacyMappingReviewRequest{ReviewStatus: "confirmed"}); !errors.Is(err, ErrCatalogLegacyMappingConflict) {
		t.Fatalf("一对多确认没有被阻断: %v", err)
	}
	var persisted models.CompetitionCatalogLegacyMapping
	if err := db.First(&persisted, mappings[1].ID).Error; err != nil {
		t.Fatal(err)
	}
	if persisted.ReviewStatus != "suggested" {
		t.Fatalf("冲突事务部分写入: %+v", persisted)
	}
}

func TestCompetitionCatalogLegacyMapperMarksEqualLegacyCandidatesAsConflict(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	active := seedActiveCatalogPackage(t, db, "a")
	legacyEvents := []models.CompetitionEvent{
		candidateEvent("LEGACY-21", "程序设计竞赛", 80, 1, nil, nil),
		candidateEvent("LEGACY-22", "程序设计竞赛", 80, 2, nil, nil),
	}
	for index := range legacyEvents {
		legacyEvents[index].CatalogPackageID = &active.ID
		if err := db.Select("*").Create(&legacyEvents[index]).Error; err != nil {
			t.Fatal(err)
		}
	}
	target, _, err := NewCompetitionCatalogImporter(db).
		Import(context.Background(), validCatalogDocument(t, "mapping-ambiguous"), 1)
	if err != nil {
		t.Fatal(err)
	}
	result, err := NewCompetitionCatalogLegacyMapper(db).Suggest(context.Background(), target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if result.ConflictCount != 1 {
		t.Fatalf("同分旧候选没有计入冲突: %+v", result)
	}
	var mapping models.CompetitionCatalogLegacyMapping
	if err := db.Where("package_id = ?", target.ID).First(&mapping).Error; err != nil {
		t.Fatal(err)
	}
	if mapping.ReviewStatus != "conflict" || mapping.LegacyEventID != legacyEvents[0].ID {
		t.Fatalf("同分候选没有进入人工决策状态: %+v", mapping)
	}
}

func TestCompetitionCatalogLegacyMapperBatchConfirmIsExplicitAndAtomic(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	active := seedActiveCatalogPackage(t, db, "a")
	legacy := candidateEvent("LEGACY-30", "程序设计竞赛", 80, 1, nil, nil)
	legacy.CatalogPackageID = &active.ID
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	target, _, err := NewCompetitionCatalogImporter(db).
		Import(context.Background(), validCatalogDocument(t, "mapping-batch"), 1)
	if err != nil {
		t.Fatal(err)
	}
	mapping := models.CompetitionCatalogLegacyMapping{
		PackageID: target.ID, CompetitionID: "NAT-006", LegacyEventID: legacy.ID,
		MatchType: "title_exact", Confidence: 1, ReviewStatus: "suggested",
	}
	if err := db.Create(&mapping).Error; err != nil {
		t.Fatal(err)
	}
	mapper := NewCompetitionCatalogLegacyMapper(db)
	if _, err := mapper.BatchConfirm(context.Background(), target.ID, 9,
		CompetitionCatalogLegacyMappingBatchConfirmRequest{}); !errors.Is(err, ErrCatalogLegacyMappingInvalid) {
		t.Fatalf("空批量确认未被拒绝: %v", err)
	}
	confirmed, err := mapper.BatchConfirm(context.Background(), target.ID, 9,
		CompetitionCatalogLegacyMappingBatchConfirmRequest{MappingIDs: []uint{mapping.ID}})
	if err != nil || confirmed != 1 {
		t.Fatalf("批量确认失败: confirmed=%d err=%v", confirmed, err)
	}
	if err := db.First(&mapping, mapping.ID).Error; err != nil {
		t.Fatal(err)
	}
	if mapping.ReviewStatus != "confirmed" || mapping.ReviewedBy == nil || *mapping.ReviewedBy != 9 {
		t.Fatalf("批量确认未完整落库: %+v", mapping)
	}
}
