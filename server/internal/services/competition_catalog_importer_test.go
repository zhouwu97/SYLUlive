package services

import (
	"context"
	"errors"
	"testing"

	"gorm.io/gorm"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/models"
)

func validCatalogDocument(t *testing.T, dataset string) dto.CompetitionCatalogDocument {
	t.Helper()
	document := dto.CompetitionCatalogDocument{
		SchemaVersion:  dto.CompetitionCatalogSchemaVersion,
		DatasetVersion: dataset, PublishStatus: "published",
		ProductionLoadAllowed: true, ItemCount: 1, SourceFilename: "catalog.json",
		Items: []dto.CompetitionCatalogRecord{{
			CompetitionID: "NAT-006", CatalogOrder: 1, Title: "程序设计竞赛",
			PrimaryCategorySlug: "computer", Tags: []string{"算法"},
			CompetitionLevel: "国家级", SchoolRecognitionStatus: "recognized",
			SchoolRecognitionGrade: "B+", CompetitionRating: "A", ImportanceScore: 90,
			EligibleEntryYears: []string{}, EligibleColleges: []string{},
			EligibleMajors:    []string{"计算机科学与技术"},
			ParticipationType: "团队赛", TeamSizeMin: 3, TeamSizeMax: 3,
			TimePrecision: "unknown", TimeStatus: "pending", Status: "published",
			RiskTags:             []string{"long_term_training"},
			SearchDisplayAllowed: true, CandidatePoolAllowed: true,
			PersonalizedRankingAllowed: false, StrongRecommendationEligible: false,
			RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
			BlockerCodes: []string{},
		}},
	}
	hash, err := ComputeCompetitionRecordHash(document.Items[0])
	if err != nil {
		t.Fatal(err)
	}
	document.Items[0].RecordHash = hash
	packageHash, err := ComputeCompetitionPackageHash(document, map[string]string{"NAT-006": hash})
	if err != nil {
		t.Fatal(err)
	}
	document.PackageHash = packageHash
	return document
}

func TestCompetitionCatalogHashMatchesOfflineTool(t *testing.T) {
	document := validCatalogDocument(t, "2026.07-v1")
	if document.Items[0].RecordHash != "288332f96f8c6134cc87c0dde02a0f8959d4000cd7d32e9a6e3244ffc0c90311" {
		t.Fatalf("record hash drifted: %s", document.Items[0].RecordHash)
	}
	if document.PackageHash != "133331ef4940e87748afafbe1e0203b9845d87592f68462f88a7af558118ea57" {
		t.Fatalf("package hash drifted: %s", document.PackageHash)
	}
}

func TestCompetitionCatalogImportSupportsRevisionsAndPackageHashIdempotency(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	importer := NewCompetitionCatalogImporter(db)
	firstDocument := validCatalogDocument(t, "2026.07-v-revision")
	first, _, err := importer.Import(context.Background(), firstDocument, 1)
	if err != nil {
		t.Fatal(err)
	}
	secondDocument := firstDocument
	secondDocument.PublishStatus = "draft"
	secondDocument.ProductionLoadAllowed = false
	refreshCatalogHashes(t, &secondDocument)
	second, _, err := importer.Import(context.Background(), secondDocument, 1)
	if err != nil {
		t.Fatal(err)
	}
	duplicate, _, err := importer.Import(context.Background(), secondDocument, 2)
	if err != nil {
		t.Fatal(err)
	}
	if first.Revision != 1 || second.Revision != 2 || duplicate.ID != second.ID {
		t.Fatalf("修订或幂等结果错误: first=%+v second=%+v duplicate=%+v", first, second, duplicate)
	}
}

func TestCompetitionCatalogActivationPersistsParentRelationship(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	document := validCatalogDocument(t, "2026.07-v-parent")
	child := document.Items[0]
	child.CompetitionID = "NAT-006-TRACK"
	child.Title = "程序设计竞赛赛道"
	child.ParentCompetitionID = "NAT-006"
	document.Items = append(document.Items, child)
	document.ItemCount = len(document.Items)
	refreshCatalogHashes(t, &document)
	importer := NewCompetitionCatalogImporter(db)
	catalog, _, err := importer.Import(context.Background(), document, 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := importer.Activate(context.Background(), catalog.ID, 1); err != nil {
		t.Fatal(err)
	}
	var parent, persisted models.CompetitionEvent
	if err := db.Where("competition_id = ?", "NAT-006").First(&parent).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Where("competition_id = ?", child.CompetitionID).First(&persisted).Error; err != nil {
		t.Fatal(err)
	}
	if persisted.ParentCompetitionID != parent.CompetitionID || persisted.ParentEventID == nil || *persisted.ParentEventID != parent.ID {
		t.Fatalf("父子赛事关系未完整落库: parent=%+v child=%+v", parent, persisted)
	}
}

func TestCompetitionCatalogConfirmedLegacyMappingReusesEventID(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	legacy := candidateEvent("LEGACY-77", "旧赛事", 10, 1, nil, nil)
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	importer := NewCompetitionCatalogImporter(db)
	document := validCatalogDocument(t, "2026.07-v-mapping")
	catalog, _, err := importer.Import(context.Background(), document, 1)
	if err != nil {
		t.Fatal(err)
	}
	mapping := models.CompetitionCatalogLegacyMapping{
		PackageID: catalog.ID, CompetitionID: document.Items[0].CompetitionID,
		LegacyEventID: legacy.ID, MatchType: "manual", Confidence: 1, ReviewStatus: "confirmed",
	}
	if err := db.Create(&mapping).Error; err != nil {
		t.Fatal(err)
	}
	if err := importer.Activate(context.Background(), catalog.ID, 1); err != nil {
		t.Fatal(err)
	}
	var activated models.CompetitionEvent
	if err := db.Where("competition_id = ?", document.Items[0].CompetitionID).First(&activated).Error; err != nil {
		t.Fatal(err)
	}
	if activated.ID != legacy.ID {
		t.Fatalf("确认映射没有复用旧 ID: got=%d want=%d", activated.ID, legacy.ID)
	}
}

func TestCompetitionCatalogValidatorRejectsHashDuplicateParentAndPermissionErrors(t *testing.T) {
	document := validCatalogDocument(t, "2026.07-v1")
	duplicate := document.Items[0]
	duplicate.ParentCompetitionID = "MISSING"
	duplicate.CandidatePoolAllowed = false
	duplicate.PersonalizedRankingAllowed = true
	document.Items = append(document.Items, duplicate)
	document.ItemCount = 2

	result := NewCompetitionCatalogValidator().Validate(document)
	if result.Status != "failed" {
		t.Fatal("invalid catalog must fail")
	}
	codes := make(map[string]bool)
	for _, issue := range result.Issues {
		codes[issue.Code] = true
	}
	for _, expected := range []string{
		"duplicate_competition_id", "package_hash_mismatch",
	} {
		if !codes[expected] {
			t.Fatalf("missing %s in %+v", expected, result.Issues)
		}
	}
}

func TestCompetitionCatalogDraftAndProductionGateCannotActivate(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	if err := db.Create(&models.CompetitionCategory{
		Name: "计算机", Slug: "computer", IsActive: true,
	}).Error; err != nil {
		t.Fatal(err)
	}
	importer := NewCompetitionCatalogImporter(db)
	for _, mutate := range []func(*dto.CompetitionCatalogDocument){
		func(document *dto.CompetitionCatalogDocument) { document.PublishStatus = "draft" },
		func(document *dto.CompetitionCatalogDocument) { document.ProductionLoadAllowed = false },
	} {
		document := validCatalogDocument(t, t.Name())
		mutate(&document)
		recordHash, _ := ComputeCompetitionRecordHash(document.Items[0])
		document.Items[0].RecordHash = recordHash
		document.PackageHash, _ = ComputeCompetitionPackageHash(document, map[string]string{"NAT-006": recordHash})
		catalog, _, err := importer.Import(context.Background(), document, 1)
		if err != nil {
			t.Fatal(err)
		}
		if err := importer.Activate(context.Background(), catalog.ID, 1); !errors.Is(err, ErrCatalogNotActivatable) {
			t.Fatalf("activation err=%v", err)
		}
		// dataset_version 必须唯一，避免第二个 case 与第一个相撞。
		db.Delete(&catalog)
	}
}

func TestCompetitionCatalogActivationIsTransactionalAndArchivesMissingRecords(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	category := models.CompetitionCategory{Name: "计算机", Slug: "computer", IsActive: true}
	if err := db.Create(&category).Error; err != nil {
		t.Fatal(err)
	}
	legacy := candidateEvent("LEGACY-99", "旧目录赛事", 10, 99, nil, nil)
	packageID := uint(99)
	legacy.CatalogPackageID = &packageID
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}

	importer := NewCompetitionCatalogImporter(db)
	document := validCatalogDocument(t, "2026.07-v2")
	catalog, validation, err := importer.Import(context.Background(), document, 7)
	if err != nil || validation.Status != "passed" {
		t.Fatalf("import err=%v validation=%+v", err, validation)
	}
	if err := importer.Activate(context.Background(), catalog.ID, 7); err != nil {
		t.Fatal(err)
	}
	var created models.CompetitionEvent
	if err := db.Where("competition_id = ?", "NAT-006").First(&created).Error; err != nil {
		t.Fatal(err)
	}
	if created.DatasetVersion != document.DatasetVersion ||
		created.RecordHash != document.Items[0].RecordHash ||
		!created.CandidatePoolAllowed {
		t.Fatalf("unexpected activated event: %+v", created)
	}
	if err := db.Where("competition_id = ?", "LEGACY-99").First(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	if legacy.Status != "archived" || legacy.CandidatePoolAllowed {
		t.Fatalf("missing record was not archived: %+v", legacy)
	}
	var activeCount int64
	if err := db.Model(&models.CompetitionCatalogPackage{}).Where("is_active = ?", true).Count(&activeCount).Error; err != nil {
		t.Fatal(err)
	}
	if activeCount != 1 {
		t.Fatalf("active packages=%d", activeCount)
	}
}

func TestCompetitionCatalogRollbackRestoresPreviousPackageEvents(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	importer := NewCompetitionCatalogImporter(db)

	firstDocument := validCatalogDocument(t, "2026.07-v1")
	first, _, err := importer.Import(context.Background(), firstDocument, 7)
	if err != nil {
		t.Fatal(err)
	}
	if err := importer.Activate(context.Background(), first.ID, 7); err != nil {
		t.Fatal(err)
	}

	secondDocument := validCatalogDocument(t, "2026.07-v2")
	secondDocument.Items[0].Title = "程序设计竞赛（新版）"
	refreshCatalogHashes(t, &secondDocument)
	second, _, err := importer.Import(context.Background(), secondDocument, 7)
	if err != nil {
		t.Fatal(err)
	}
	if err := importer.Activate(context.Background(), second.ID, 7); err != nil {
		t.Fatal(err)
	}
	if err := importer.Rollback(context.Background(), second.ID, 9); err != nil {
		t.Fatal(err)
	}

	var restored models.CompetitionEvent
	if err := db.Where("competition_id = ?", "NAT-006").First(&restored).Error; err != nil {
		t.Fatal(err)
	}
	if restored.Title != firstDocument.Items[0].Title ||
		restored.RecordHash != firstDocument.Items[0].RecordHash ||
		restored.DatasetVersion != firstDocument.DatasetVersion {
		t.Fatalf("previous event not restored: %+v", restored)
	}
	var active models.CompetitionCatalogPackage
	if err := db.Where("is_active = ?", true).First(&active).Error; err != nil {
		t.Fatal(err)
	}
	if active.ID != first.ID {
		t.Fatalf("active package=%d want=%d", active.ID, first.ID)
	}
	var audit models.CompetitionCatalogAuditLog
	if err := db.Where("action = ? AND result = ?", "catalog_rollback", "success").
		Order("id DESC").First(&audit).Error; err != nil {
		t.Fatal(err)
	}
}

func TestCompetitionCatalogActivationFailureKeepsCurrentPackage(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	requireCatalogCategory(t, db)
	importer := NewCompetitionCatalogImporter(db)

	firstDocument := validCatalogDocument(t, "2026.07-v1")
	first, _, err := importer.Import(context.Background(), firstDocument, 7)
	if err != nil {
		t.Fatal(err)
	}
	if err := importer.Activate(context.Background(), first.ID, 7); err != nil {
		t.Fatal(err)
	}

	brokenDocument := validCatalogDocument(t, "2026.07-v2")
	brokenDocument.Items[0].PrimaryCategorySlug = "missing-category"
	brokenDocument.Items[0].Title = "不应落库的新标题"
	refreshCatalogHashes(t, &brokenDocument)
	broken, _, err := importer.Import(context.Background(), brokenDocument, 7)
	if err != nil {
		t.Fatal(err)
	}
	if err := importer.Activate(context.Background(), broken.ID, 7); err == nil {
		t.Fatal("activation with missing category must fail")
	}

	var active models.CompetitionCatalogPackage
	if err := db.Where("is_active = ?", true).First(&active).Error; err != nil {
		t.Fatal(err)
	}
	if active.ID != first.ID {
		t.Fatalf("failed activation changed active package: %d", active.ID)
	}
	var event models.CompetitionEvent
	if err := db.Where("competition_id = ?", "NAT-006").First(&event).Error; err != nil {
		t.Fatal(err)
	}
	if event.Title != firstDocument.Items[0].Title ||
		event.RecordHash != firstDocument.Items[0].RecordHash ||
		event.Status != "published" {
		t.Fatalf("failed activation partially updated event: %+v", event)
	}
}

func requireCatalogCategory(t *testing.T, db *gorm.DB) {
	t.Helper()
	if err := db.Create(&models.CompetitionCategory{
		Name: "计算机", Slug: "computer", IsActive: true,
	}).Error; err != nil {
		t.Fatal(err)
	}
}

func refreshCatalogHashes(t *testing.T, document *dto.CompetitionCatalogDocument) {
	t.Helper()
	hashes := make(map[string]string, len(document.Items))
	for index := range document.Items {
		hash, err := ComputeCompetitionRecordHash(document.Items[index])
		if err != nil {
			t.Fatal(err)
		}
		document.Items[index].RecordHash = hash
		hashes[document.Items[index].CompetitionID] = hash
	}
	packageHash, err := ComputeCompetitionPackageHash(*document, hashes)
	if err != nil {
		t.Fatal(err)
	}
	document.PackageHash = packageHash
}
