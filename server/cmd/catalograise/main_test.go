package main

import (
	"testing"

	"shenliyuan/internal/dto"
	"shenliyuan/internal/services"
)

func baseRecord(id string, pool bool, colleges []string) dto.CompetitionCatalogRecord {
	return dto.CompetitionCatalogRecord{
		CompetitionID: id, Title: id + " 赛事", Status: "published",
		CandidatePoolAllowed: pool, SearchDisplayAllowed: true,
		RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
		EligibleColleges: colleges, EligibleMajors: []string{}, EligibleEntryYears: []string{},
		Tags: []string{}, RiskTags: []string{}, BlockerCodes: []string{},
	}
}

func baseDocument(records ...dto.CompetitionCatalogRecord) dto.CompetitionCatalogDocument {
	return dto.CompetitionCatalogDocument{
		SchemaVersion: "sylulive-competition-catalog/2.2", DatasetVersion: "v1",
		PublishStatus: "published", ProductionLoadAllowed: true,
		ItemCount: len(records), Items: records,
	}
}

func TestRaisePilotScopeOnlyFlipsMatchingCollege(t *testing.T) {
	document := baseDocument(
		baseRecord("A", true, []string{"信息科学与工程学院"}),
		baseRecord("B", true, []string{"艺术设计学院"}),
		baseRecord("C", false, []string{"信息科学与工程学院"}),
	)
	result, err := raisePersonalizedRanking(document, raiseOptions{College: "信息科学与工程学院"})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Changed) != 1 || result.Changed[0] != "A" {
		t.Fatalf("翻转集合=%v", result.Changed)
	}
	byID := map[string]dto.CompetitionCatalogRecord{}
	for _, record := range result.Document.Items {
		byID[record.CompetitionID] = record
	}
	if !byID["A"].PersonalizedRankingAllowed {
		t.Fatal("范围内的候选池赛事必须翻转")
	}
	if byID["B"].PersonalizedRankingAllowed {
		t.Fatal("范围外的赛事不得翻转（试点包边界）")
	}
	// 候选池外一律保持关闭：校验器规定「未进候选池不得开放个性化排序」。
	if byID["C"].PersonalizedRankingAllowed {
		t.Fatal("候选池外的赛事不得翻转")
	}
	if len(result.SkippedPoolClosed) != 1 || len(result.SkippedOutOfScope) != 1 {
		t.Fatalf("跳过统计不符：%+v", result)
	}
}

func TestRaiseRecomputesHashesWithProductionImplementation(t *testing.T) {
	document := baseDocument(baseRecord("A", true, []string{"信息科学与工程学院"}))
	result, err := raisePersonalizedRanking(document, raiseOptions{All: true, DatasetVersion: "v2"})
	if err != nil {
		t.Fatal(err)
	}
	record := result.Document.Items[0]
	if record.RecordHash == "" || len(record.RecordHash) != 64 {
		t.Fatalf("记录摘要未重算：%q", record.RecordHash)
	}
	// 摘要必须与服务端同一份实现的结果一致，否则导入时校验必然失败。
	expected, err := services.ComputeCompetitionRecordHash(record)
	if err != nil {
		t.Fatal(err)
	}
	if record.RecordHash != expected {
		t.Fatalf("记录摘要与服务端实现不一致: %s vs %s", record.RecordHash, expected)
	}
	packageHash, err := services.ComputeCompetitionPackageHash(
		result.Document, map[string]string{"A": record.RecordHash},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Document.PackageHash != packageHash {
		t.Fatalf("包摘要与服务端实现不一致: %s vs %s", result.Document.PackageHash, packageHash)
	}
	// 翻转必须真的改变了摘要，否则等于没生效。
	original, err := services.ComputeCompetitionRecordHash(document.Items[0])
	if err != nil {
		t.Fatal(err)
	}
	if original == record.RecordHash {
		t.Fatal("翻转后记录摘要未变化，说明字段没被写入")
	}
}

func TestRaiseRejectsAlreadyOpenPoolClosedRecord(t *testing.T) {
	record := baseRecord("C", false, nil)
	record.PersonalizedRankingAllowed = true
	if _, err := raisePersonalizedRanking(baseDocument(record), raiseOptions{All: true}); err == nil {
		t.Fatal("候选池外却已开放排序的输入包必须被拒绝")
	}
}

func TestRaiseRejectsStrongRecommendationRecord(t *testing.T) {
	record := baseRecord("A", true, nil)
	record.StrongRecommendationEligible = true
	if _, err := raisePersonalizedRanking(baseDocument(record), raiseOptions{All: true}); err == nil {
		t.Fatal("强推荐字段为 true 时应拒绝处理，避免误改强推荐语义")
	}
}

func TestRaiseIsIdempotent(t *testing.T) {
	document := baseDocument(
		baseRecord("A", true, []string{"信息科学与工程学院"}),
		baseRecord("B", true, []string{"艺术设计学院"}),
	)
	first, err := raisePersonalizedRanking(document, raiseOptions{All: true})
	if err != nil {
		t.Fatal(err)
	}
	second, err := raisePersonalizedRanking(first.Document, raiseOptions{All: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(second.Changed) != 0 || second.AlreadyOpen != 2 {
		t.Fatalf("重复执行不应再次翻转：%+v", second)
	}
	// 摘要必须稳定：两次执行同一输入得到同一结果。
	if first.Document.PackageHash != second.Document.PackageHash {
		t.Fatalf("包摘要不稳定: %s vs %s", first.Document.PackageHash, second.Document.PackageHash)
	}
}
