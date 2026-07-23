package handlers

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"gorm.io/datatypes"

	"shenliyuan/internal/models"
)

func capabilityProfileRequest(t *testing.T, handler *CompetitionHandler, userID uint) competitionCapabilityProfileResponse {
	t.Helper()
	recorder := preferenceRequest(t, handler.GetCompetitionCapabilityProfile, http.MethodGet, "", userID)
	if recorder.Code != http.StatusOK {
		t.Fatalf("profile status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response competitionCapabilityProfileResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestCompetitionCapabilityProfileReturnsStableEmptyStructure(t *testing.T) {
	db := newCompetitionTestDB(t)
	profile := capabilityProfileRequest(t, NewCompetitionHandler(db), 71)
	if profile.PreferenceConfigured || profile.VerifiedAwardCount != 0 || profile.SelfReportedAwardCount != 0 {
		t.Fatalf("empty profile=%+v", profile)
	}
	if profile.Goals == nil || profile.SkillSummary == nil || profile.RoleSummary == nil || profile.DirectionTags == nil || profile.PreferredRoles == nil {
		t.Fatalf("empty arrays must not be null: %+v", profile)
	}
}

func TestCompetitionCapabilityProfileSeparatesEvidenceAndFiltersStatuses(t *testing.T) {
	db := newCompetitionTestDB(t)
	preference := models.UserCompetitionPreference{
		UserID: 72, Goals: datatypes.JSON(`["ability","exploration"]`), DirectionTags: datatypes.JSON(`["程序设计","数据分析"]`),
		SkillTags: datatypes.JSON(`["Python"]`), PreferredRoles: datatypes.JSON(`["developer"]`),
		WeeklyHours: 7, AcceptLongTermTraining: true, ExperienceLevel: "participated",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}
	awards := []models.UserCompetitionAward{
		{UserID: 72, CompetitionTitle: "核验赛事", CompetitionYear: 2026, AwardName: "一等奖", CompetitionStage: "national", Role: "developer", SkillTags: datatypes.JSON(`["Python","Python","算法"]`), EvidenceFileIDs: datatypes.JSON(`[]`), VerificationStatus: "verified", Visibility: "private"},
		{UserID: 72, CompetitionTitle: "自报赛事", CompetitionYear: 2025, AwardName: "参赛", CompetitionStage: "school", Role: "modeler", SkillTags: datatypes.JSON(`["Python","建模"]`), EvidenceFileIDs: datatypes.JSON(`[]`), VerificationStatus: "self_reported", Visibility: "private"},
		{UserID: 72, CompetitionTitle: "待核验", CompetitionYear: 2025, AwardName: "参赛", CompetitionStage: "school", Role: "designer", SkillTags: datatypes.JSON(`["设计"]`), EvidenceFileIDs: datatypes.JSON(`[]`), VerificationStatus: "pending", Visibility: "private"},
		{UserID: 72, CompetitionTitle: "已驳回", CompetitionYear: 2025, AwardName: "参赛", CompetitionStage: "school", Role: "hardware", SkillTags: datatypes.JSON(`["硬件"]`), EvidenceFileIDs: datatypes.JSON(`[]`), VerificationStatus: "rejected", Visibility: "private"},
		{UserID: 73, CompetitionTitle: "其他用户", CompetitionYear: 2026, AwardName: "一等奖", CompetitionStage: "national", Role: "developer", SkillTags: datatypes.JSON(`["泄露技能"]`), EvidenceFileIDs: datatypes.JSON(`[]`), VerificationStatus: "verified", Visibility: "private"},
	}
	if err := db.Create(&awards).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.Delete(&awards[1]).Error; err != nil {
		t.Fatal(err)
	}

	profile := capabilityProfileRequest(t, NewCompetitionHandler(db), 72)
	if !profile.PreferenceConfigured || profile.WeeklyHours != 7 || !profile.AcceptLongTermTraining {
		t.Fatalf("preference fields=%+v", profile)
	}
	if strings.Join(profile.Goals, ",") != "ability,exploration" {
		t.Fatalf("goals=%+v", profile.Goals)
	}
	if profile.VerifiedAwardCount != 1 || profile.SelfReportedAwardCount != 0 {
		t.Fatalf("award counts=%+v", profile)
	}
	if len(profile.SkillSummary) != 2 || profile.SkillSummary[0].Skill != "Python" || profile.SkillSummary[0].VerifiedCount != 1 {
		t.Fatalf("skill summary=%+v", profile.SkillSummary)
	}
	if len(profile.RoleSummary) != 1 || profile.RoleSummary[0].Role != "developer" || profile.RoleSummary[0].VerifiedCount != 1 {
		t.Fatalf("role summary=%+v", profile.RoleSummary)
	}
	if strings.Join(profile.DirectionTags, ",") != "程序设计,数据分析" || strings.Join(profile.PreferredRoles, ",") != "developer" {
		t.Fatalf("preference arrays=%+v", profile)
	}
}

func TestCompetitionCapabilityProfileDoesNotExposePrivateEvidenceFields(t *testing.T) {
	db := newCompetitionTestDB(t)
	if err := db.Create(&models.UserCompetitionAward{
		UserID: 74, CompetitionTitle: "隐私检查", CompetitionYear: 2026, AwardName: "一等奖",
		CompetitionStage: "national", Role: "developer", SkillTags: datatypes.JSON(`["Go"]`),
		EvidenceFileIDs: datatypes.JSON(`[123]`), VerificationStatus: "verified", VerificationNote: "内部核验备注",
		VerifiedBy: func() *uint { value := uint(99); return &value }(), Visibility: "private",
	}).Error; err != nil {
		t.Fatal(err)
	}
	recorder := preferenceRequest(t, NewCompetitionHandler(db).GetCompetitionCapabilityProfile, http.MethodGet, "", 74)
	body := recorder.Body.String()
	for _, forbidden := range []string{"evidence", "verified_by", "verification_note", "file_id", "path"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("response leaks %q: %s", forbidden, body)
		}
	}
}

func TestCompetitionCapabilityProfileRequiresAuthentication(t *testing.T) {
	db := newCompetitionTestDB(t)
	recorder := preferenceRequest(t, NewCompetitionHandler(db).GetCompetitionCapabilityProfile, http.MethodGet, "", 0)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
}
