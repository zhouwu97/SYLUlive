package services

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"gorm.io/datatypes"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

func newCompetitionServiceTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", t.Name())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(
		&models.User{}, &models.UserCompetitionPreference{}, &models.UserCompetitionAward{},
		&models.CompetitionCategory{}, &models.CompetitionCatalogPackage{},
		&models.CompetitionEvent{}, &models.CompetitionCatalogAuditLog{},
		&models.CompetitionCatalogLegacyMapping{}, &models.CompetitionCatalogActivationSnapshot{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

func TestCompetitionCandidateEngineReadsOnlyActivePackage(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	active := models.CompetitionCatalogPackage{
		SchemaVersion: "sylulive-competition-catalog/2.2", DatasetVersion: "active-v1",
		Revision: 1, PackageHash: strings.Repeat("a", 64), LifecycleStatus: "active",
		PublishStatus: "published", ProductionLoadAllowed: true, ItemCount: 1,
		ValidationStatus: "passed", ValidationResult: datatypes.JSON(`{}`), Payload: datatypes.JSON(`{}`),
		ImportedBy: 1, ImportedAt: time.Now(), IsActive: true,
	}
	if err := db.Create(&active).Error; err != nil {
		t.Fatal(err)
	}
	legacy := candidateEvent("LEGACY-1", "旧赛事", 100, 1, nil, nil)
	governed := candidateEvent("NAT-001", "活动包赛事", 10, 2, nil, nil)
	governed.DatasetVersion = active.DatasetVersion
	governed.CatalogPackageID = &active.ID
	if err := db.Select("*").Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Select("*").Create(&governed).Error; err != nil {
		t.Fatal(err)
	}
	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Total != 1 || result.Groups[0].Items[0].CompetitionID != governed.CompetitionID {
		t.Fatalf("活动包作用域混入旧数据: %+v", result.Groups)
	}
}

func competitionJSON(values ...string) datatypes.JSON {
	encoded, _ := json.Marshal(values)
	return datatypes.JSON(encoded)
}

func readyCompetitionUser(t *testing.T, db *gorm.DB) models.User {
	t.Helper()
	now := time.Now()
	user := models.User{
		StudentID: "20260001", PasswordHash: "test", Nickname: "候选测试",
		StudentVerifiedAt: &now, EduAuthorized: true, EduBound: true,
		EduGrade: "本科2023级", EduCollege: "信息科学与工程学院", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	return user
}

func candidateEvent(
	id, title string,
	importance, order int,
	majors, colleges []string,
) models.CompetitionEvent {
	eventStart := time.Now().AddDate(0, 1, 0)
	return models.CompetitionEvent{
		CompetitionID: id, DatasetVersion: "legacy", RecordHash: fmt.Sprintf("%064d", order+1),
		CatalogOrder: order, Title: title, Summary: title, Status: "published",
		ImportanceScore: importance, EligibleEntryYears: competitionJSON(),
		EligibleMajors: competitionJSON(majors...), EligibleColleges: competitionJSON(colleges...),
		Tags: competitionJSON(), RiskTags: competitionJSON(), BlockerCodes: competitionJSON(),
		SearchDisplayAllowed: true, CandidatePoolAllowed: true,
		RecommendationPermissionLevel: "low", AIMode: "candidate_explanation",
		TimeStatus: "confirmed", TimePrecision: "exact", EventStart: &eventStart,
	}
}

func TestCompetitionCandidateEngineFiltersEligibilityAndCandidateGate(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	events := []models.CompetitionEvent{
		candidateEvent("NAT-001", "专业赛事", 80, 1, []string{"计算机科学与技术"}, nil),
		candidateEvent("NAT-002", "其他专业赛事", 90, 2, []string{"机械工程"}, nil),
		candidateEvent("NAT-003", "学院赛事", 70, 3, nil, []string{"信息科学与工程学院"}),
		candidateEvent("NAT-004", "通用赛事", 60, 4, nil, nil),
	}
	blocked := candidateEvent("NAT-005", "目录阻断赛事", 100, 0, nil, nil)
	blocked.CandidatePoolAllowed = false
	events = append(events, blocked)
	for index := range events {
		if err := db.Select("*").Create(&events[index]).Error; err != nil {
			t.Fatal(err)
		}
	}

	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Total != 3 {
		t.Fatalf("total=%d groups=%+v", result.Total, result.Groups)
	}
	if len(result.Groups) != 3 ||
		result.Groups[0].Key != "major_match" ||
		result.Groups[1].Key != "college_match" ||
		result.Groups[2].Key != "general_match" {
		t.Fatalf("unexpected groups: %+v", result.Groups)
	}
}

func TestCompetitionCandidateEnginePreferenceCannotReorderClosedCatalog(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	preference := models.UserCompetitionPreference{
		UserID: user.ID, Goals: competitionJSON("ability"),
		DirectionTags: competitionJSON("算法"), SkillTags: competitionJSON(),
		PreferredRoles: competitionJSON(), WeeklyHours: 14, ExperienceLevel: "beginner",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	first := candidateEvent("NAT-010", "软件工程实践", 90, 1, []string{"计算机科学与技术"}, nil)
	second := candidateEvent("NAT-011", "算法专项赛事", 10, 2, []string{"计算机科学与技术"}, nil)
	if err := db.Select("*").Create(&first).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Select("*").Create(&second).Error; err != nil {
		t.Fatal(err)
	}

	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	items := result.Groups[0].Items
	if len(items) != 2 || items[0].CompetitionID != "NAT-010" {
		t.Fatalf("用户偏好改变了目录禁止个性化排序时的顺序: %+v", items)
	}
	if result.Catalog.PersonalizedRankingAllowed {
		t.Fatal("目录未授权时不能声明允许个性化排序")
	}
}

func TestCompetitionCandidateEngineUsesCatalogOrderWithoutImportanceOrDeadlinePriority(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	now := time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)
	first := candidateEvent("NAT-030", "目录第一项", 1, 1, nil, nil)
	first.RegistrationEnd = ptrTime(now.AddDate(0, 2, 0))
	second := candidateEvent("NAT-031", "高重要度且临近截止", 100, 2, nil, nil)
	second.RegistrationEnd = ptrTime(now.AddDate(0, 0, 1))
	if err := db.Select("*").Create(&first).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Select("*").Create(&second).Error; err != nil {
		t.Fatal(err)
	}

	result, err := NewCompetitionCandidateEngineWithClock(db, func() time.Time { return now }).
		BuildCandidates(context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20})
	if err != nil {
		t.Fatal(err)
	}
	items := result.Groups[0].Items
	if len(items) != 2 || items[0].CompetitionID != first.CompetitionID {
		t.Fatalf("重要度或临近截止改变了目录顺序: %+v", items)
	}
}

func ptrTime(value time.Time) *time.Time { return &value }

func TestCompetitionCandidateEngineReturnsProfileNotReadyWithoutCandidates(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := models.User{StudentID: "20260002", PasswordHash: "test", Nickname: "未认证"}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.ProfileReady || result.Total != 0 || len(result.Groups) != 0 {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestCompetitionCandidateEngineKeepsPrimaryGroupWhenTimePending(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	event := candidateEvent(
		"NAT-020", "程序设计长期训练赛事", 80, 1,
		[]string{"计算机科学与技术"}, nil,
	)
	event.TimeStatus = "pending"
	event.EventStart = nil
	event.RiskTags = competitionJSON("team_dependency", "unknown_internal_risk")
	if err := db.Select("*").Create(&event).Error; err != nil {
		t.Fatal(err)
	}
	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Groups) != 1 || result.Groups[0].Key != "major_match" {
		t.Fatalf("待确认时间覆盖了专业主分组: %+v", result.Groups)
	}
	item := result.Groups[0].Items[0]
	if !item.HasPendingInformation {
		t.Fatal("待确认状态未返回")
	}
	if item.MatchDimensions.Direction != "unknown" ||
		item.MatchDimensions.Skill != "unknown" ||
		item.MatchDimensions.Time != "unknown" {
		t.Fatalf("缺少结构化目录字段时不应猜测匹配维度: %+v", item.MatchDimensions)
	}
	if fmt.Sprint(item.Cautions) != "[依赖稳定团队协作 存在待核实风险]" {
		t.Fatalf("风险文案未按注册表收口: %+v", item.Cautions)
	}
}

func TestCompetitionUserContextExcludesPrivateAwardFields(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	award := models.UserCompetitionAward{
		UserID: user.ID, CompetitionTitle: "测试", CompetitionYear: 2026,
		AwardName: "一等奖", CompetitionStage: "national", Role: "developer",
		SkillTags: competitionJSON("C++"), EvidenceFileIDs: competitionJSON("private-file"),
		ContributionSummary: "不得外发的经历原文", VerificationNote: "不得外发的审核备注",
		VerificationStatus: "verified", Visibility: "private",
	}
	if err := db.Create(&award).Error; err != nil {
		t.Fatal(err)
	}
	value, err := NewCompetitionUserContextBuilder(db).BuildCompetitionUserContext(context.Background(), user.ID)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(value)
	for _, forbidden := range []string{"不得外发", "private-file", "verification_note", "contribution_summary"} {
		if string(encoded) == "" || containsText(string(encoded), forbidden) {
			t.Fatalf("画像泄露私有字段 %q: %s", forbidden, encoded)
		}
	}
	if len(value.Skills) != 1 || value.Skills[0].VerifiedCount != 1 {
		t.Fatalf("unexpected structured summary: %+v", value.Skills)
	}
}

func containsText(value, expected string) bool {
	for index := 0; index+len(expected) <= len(value); index++ {
		if value[index:index+len(expected)] == expected {
			return true
		}
	}
	return false
}
