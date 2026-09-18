package services

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	// 使用纯 Go 驱动，与包内多数测试保持一致；cgo 版需要 C 工具链，
	// 在无 CGO 的环境下无法运行，会导致这批测试被静默跳过验证。
	"github.com/glebarez/sqlite"
	"gorm.io/datatypes"
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
		&models.User{}, &models.AcademicIdentityBinding{}, &models.UserCompetitionPreference{}, &models.UserCompetitionAward{},
		&models.CompetitionCategory{}, &models.CompetitionCatalogPackage{},
		&models.CompetitionEvent{}, &models.CompetitionCatalogAuditLog{},
		&models.CompetitionCatalogLegacyMapping{}, &models.CompetitionCatalogActivationSnapshot{},
		// 候选引擎会读取「已加入计划」作为排序行为信号，测试库需同步建表。
		&models.UserCompetitionCalendarItem{},
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
	if err := db.Create(&models.AcademicIdentityBinding{UserID: user.ID, ProviderID: models.AcademicProviderUndergraduate,
		StudentID: user.StudentID, VerifiedAt: now, VerificationMethod: "test", VerificationVersion: "v1"}).Error; err != nil {
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
	// 行为变更（本次修复）：NAT-002 的专业范围（机械工程）与用户专业
	// （计算机科学与技术）不匹配时，旧实现直接丢弃；现在必须降级到通用候选。
	// 详见 docs/plans/competition-recommendation-plan.md §2 P0-2。
	if result.Total != 4 {
		t.Fatalf("total=%d groups=%+v", result.Total, result.Groups)
	}
	if len(result.Groups) != 3 ||
		result.Groups[0].Key != "major_match" ||
		result.Groups[1].Key != "college_match" ||
		result.Groups[2].Key != "general_match" {
		t.Fatalf("unexpected groups: %+v", result.Groups)
	}
	wantCounts := map[string]int{"major_match": 1, "college_match": 1, "general_match": 2}
	for _, group := range result.Groups {
		if group.Count != wantCounts[group.Key] {
			t.Fatalf("分组 %s 计数=%d want=%d", group.Key, group.Count, wantCounts[group.Key])
		}
	}
	// blocked 赛事必须仍然被治理门排除，不得因本次改动泄漏进结果。
	for _, group := range result.Groups {
		for _, item := range group.Items {
			if item.CompetitionID == "NAT-005" {
				t.Fatal("候选池未开放的赛事不得进入结果")
			}
		}
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

func TestCompetitionCandidateEnginePassesPreferenceTagsIntoScoring(t *testing.T) {
	// 回归用例：画像层此前漏读 user_competition_preferences.skill_tags，
	// 引擎里取到的 SkillTags 恒为空，导致「技能」维度永远显示「尚未确认」、
	// 技能分恒为 0 的死分量。本用例同时覆盖方向与技能两条桥接链路。
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	preference := models.UserCompetitionPreference{
		UserID: user.ID, Goals: competitionJSON(),
		DirectionTags: competitionJSON("程序设计"), SkillTags: competitionJSON("Python"),
		PreferredRoles: competitionJSON(), ExperienceLevel: "beginner",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	// 赛事只带目录真实的粗分类标签，与方向词、技能词零重叠。
	event := candidateEvent("NAT-041", "程序设计赛事", 50, 1, []string{"计算机类"}, nil)
	event.Tags = competitionJSON("工程实践")
	if err := db.Select("*").Create(&event).Error; err != nil {
		t.Fatal(err)
	}

	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.Total != 1 {
		t.Fatalf("total=%d groups=%+v", result.Total, result.Groups)
	}
	item := result.Groups[0].Items[0]
	if item.MatchDimensions.Direction != "matched" {
		t.Fatalf("方向标签未接入打分：%+v", item.MatchDimensions)
	}
	if item.MatchDimensions.Skill != "matched" {
		t.Fatalf("技能标签未接入打分：%+v", item.MatchDimensions)
	}
	if item.MatchTier == "" || item.MatchTier == "none" {
		t.Fatalf("命中专业簇与偏好后不应无档位：%q", item.MatchTier)
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
	// 画像未就绪时必须说明缺什么，前端才能给出可操作的引导，
	// 而不是让用户对着一个空列表自己猜（旧实现只有一句 404 或空白）。
	if result.ReasonCode != ReasonProfileIncomplete {
		t.Fatalf("reason_code=%q", result.ReasonCode)
	}
	if len(result.MissingFields) == 0 {
		t.Fatal("画像未就绪时必须列出缺失字段")
	}
}

// 用户手动纠正的专业簇必须优先于按专业名推断的结果（边界契约 B7）。
// 这是长尾专业唯一的自救路径：推断不出来时，用户自己指定即可参与匹配。
func TestCompetitionCandidateEngineHonoursMajorClusterOverride(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	// 把专业换成一个字典里没有、粗归类也命中不了的名称。
	if err := db.Model(&models.User{}).Where("id = ?", user.ID).
		Update("edu_major", "丝路特色试验班").Error; err != nil {
		t.Fatal(err)
	}
	preference := models.UserCompetitionPreference{
		UserID: user.ID, Goals: competitionJSON(),
		DirectionTags: competitionJSON(), SkillTags: competitionJSON(),
		PreferredRoles: competitionJSON(), ExperienceLevel: "beginner",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	event := candidateEvent("NAT-050", "计算机类赛事", 50, 1, []string{"计算机类"}, nil)
	if err := db.Select("*").Create(&event).Error; err != nil {
		t.Fatal(err)
	}

	// 纠正之前：专业无法映射，必须上报可见缺口，且事件只能落进通用池。
	result, err := NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.ReasonCode != ReasonClusterUnmapped {
		t.Fatalf("专业无映射必须上报缺口，实际 reason_code=%q", result.ReasonCode)
	}
	if result.Groups[0].Key != "general_match" {
		t.Fatalf("纠正前不应进入专业相关组：%+v", result.Groups)
	}

	// 用户手动纠正为「计算机类」后，应立即按专业相关命中（无需重启、无需缓存刷新）。
	override := competitionJSON("计算机类")
	if err := db.Model(&models.UserCompetitionPreference{}).Where("user_id = ?", user.ID).
		Update("major_cluster_override", override).Error; err != nil {
		t.Fatal(err)
	}
	result, err = NewCompetitionCandidateEngine(db).BuildCandidates(
		context.Background(), user.ID, CandidateFilter{Page: 1, PageSize: 20},
	)
	if err != nil {
		t.Fatal(err)
	}
	if result.ReasonCode != "" {
		t.Fatalf("已纠正后不应再上报缺口：%q", result.ReasonCode)
	}
	if len(result.Groups) != 1 || result.Groups[0].Key != "major_match" {
		t.Fatalf("纠正后应进入专业相关组：%+v", result.Groups)
	}
	if item := result.Groups[0].Items[0]; len(item.MatchedClusters) == 0 ||
		item.MatchedClusters[0] != "计算机类" {
		t.Fatalf("未回传命中的专业簇：%+v", item.MatchedClusters)
	}
}

// 诊断计数必须能解释「为什么是 0 条」：治理门条数、筛选后条数、年级淘汰数与分组计数。
func TestCompetitionCandidateEngineReportsPipelineDiagnostics(t *testing.T) {
	db := newCompetitionServiceTestDB(t)
	user := readyCompetitionUser(t, db)
	events := []models.CompetitionEvent{
		candidateEvent("NAT-060", "专业赛事", 60, 1, []string{"计算机类"}, nil),
		candidateEvent("NAT-061", "学院赛事", 50, 2, nil, []string{"信息科学与工程学院"}),
		candidateEvent("NAT-062", "通用赛事", 40, 3, nil, nil),
	}
	gradeBlocked := candidateEvent("NAT-063", "研究生赛事", 90, 4, []string{"计算机类"}, nil)
	gradeBlocked.EligibleEntryYears = competitionJSON("研究生")
	events = append(events, gradeBlocked)
	blocked := candidateEvent("NAT-064", "候选池外赛事", 100, 5, nil, nil)
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
	diagnostics := result.Diagnostics
	if diagnostics == nil {
		t.Fatal("缺少管线诊断计数")
	}
	// 治理门排除 NAT-064：310 条在真实目录下的对应关系就是 275 条进候选池。
	if diagnostics.Scoped != 4 || diagnostics.Matched != 4 {
		t.Fatalf("治理门计数错误：%+v", diagnostics)
	}
	if diagnostics.GradeExcluded != 1 {
		t.Fatalf("年级淘汰计数错误：%+v", diagnostics)
	}
	if diagnostics.MajorMatch != 1 || diagnostics.CollegeMatch != 1 || diagnostics.GeneralMatch != 1 {
		t.Fatalf("分组计数错误：%+v", diagnostics)
	}
	if diagnostics.Returned != 3 || diagnostics.Returned != result.Total {
		t.Fatalf("返回条数错误：%+v total=%d", diagnostics, result.Total)
	}
	// 目录未授权时不得声明任何赛事参与个性化排序。
	if diagnostics.Rankable != 0 || result.Catalog.PersonalizedRankingAllowed {
		t.Fatalf("未授权目录不应有可排序赛事：%+v", diagnostics)
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
