package competitioncontext

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/datatypes"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/models"
)

func newContextTestDB(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared", t.Name())
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(
		&models.User{}, &models.AcademicIdentityBinding{},
		&models.UserCompetitionPreference{}, &models.UserCompetitionProfile{}, &models.UserCompetitionAward{},
	); err != nil {
		t.Fatal(err)
	}
	return db
}

func contextJSON(values ...string) datatypes.JSON {
	encoded, _ := json.Marshal(values)
	return datatypes.JSON(encoded)
}

func readyContextUser(t *testing.T, db *gorm.DB) models.User {
	t.Helper()
	now := time.Now()
	user := models.User{
		StudentID: "20260001", PasswordHash: "test", Nickname: "画像测试",
		StudentVerifiedAt: &now, EduAuthorized: true, EduBound: true,
		EduGrade: "本科2023级", EduCollege: "信息科学与工程学院", EduMajor: "计算机科学与技术",
	}
	if err := db.Create(&user).Error; err != nil {
		t.Fatal(err)
	}
	binding := models.AcademicIdentityBinding{
		UserID: user.ID, ProviderID: models.AcademicProviderUndergraduate,
		StudentID: user.StudentID, VerifiedAt: now,
		VerificationMethod: models.AcademicVerificationMethodSchoolProfile, VerificationVersion: "v1",
	}
	if err := db.Create(&binding).Error; err != nil {
		t.Fatal(err)
	}
	return user
}

func TestBuildCompetitionUserContextUsesProfileEntryYearForGradeAndVersion(t *testing.T) {
	db := newContextTestDB(t)
	user := readyContextUser(t, db)
	first, err := NewBuilder(db).BuildCompetitionUserContext(context.Background(), user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if first.Grade != "本科2023级" {
		t.Fatalf("初始年级 = %q", first.Grade)
	}
	if err := db.Create(&models.UserCompetitionProfile{
		UserID: user.ID, EntryYear: "2024", College: user.EduCollege, Major: user.EduMajor,
		Provenance: models.UserCompetitionProfileProvenanceSelfReported,
	}).Error; err != nil {
		t.Fatal(err)
	}
	second, err := NewBuilder(db).BuildCompetitionUserContext(context.Background(), user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if second.EntryYear != "2024" || second.Grade != "本科2024级" {
		t.Fatalf("画像年份未同步到年级：entry=%q grade=%q", second.EntryYear, second.Grade)
	}
	if first.ProfileVersion == second.ProfileVersion {
		t.Fatal("修改入学年份后画像版本不得保持不变")
	}
}

// 回归用例：SkillTags 必须从 user_competition_preferences.skill_tags 读出。
// 此前 UserContext 没有这个字段，下游取到的技能偏好恒为空，
// 造成「技能」维度永远显示「尚未确认」、技能分恒为 0 的死分量。
func TestBuildCompetitionUserContextReadsSkillTags(t *testing.T) {
	db := newContextTestDB(t)
	user := readyContextUser(t, db)
	preference := models.UserCompetitionPreference{
		UserID: user.ID, Goals: contextJSON("ability"),
		DirectionTags: contextJSON("程序设计"), SkillTags: contextJSON("Python", "算法"),
		PreferredRoles: contextJSON(), WeeklyHours: 7, ExperienceLevel: "beginner",
	}
	if err := db.Create(&preference).Error; err != nil {
		t.Fatal(err)
	}

	result, err := NewBuilder(db).BuildCompetitionUserContext(context.Background(), user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.SkillTags) != 2 || result.SkillTags[0] != "Python" || result.SkillTags[1] != "算法" {
		t.Fatalf("技能标签未读出：%+v", result.SkillTags)
	}
	if len(result.DirectionTags) != 1 || result.DirectionTags[0] != "程序设计" {
		t.Fatalf("方向标签未读出：%+v", result.DirectionTags)
	}
	if !result.PreferenceConfigured {
		t.Fatal("存在偏好记录时必须标记为已配置")
	}
}

// 没有偏好记录时必须是空切片而不是 nil，避免下游把「没填」与「字段缺失」混在一起。
func TestBuildCompetitionUserContextWithoutPreferenceReturnsEmptySkillTags(t *testing.T) {
	db := newContextTestDB(t)
	user := readyContextUser(t, db)

	result, err := NewBuilder(db).BuildCompetitionUserContext(context.Background(), user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if result.SkillTags == nil || len(result.SkillTags) != 0 {
		t.Fatalf("无偏好时技能标签应为空切片：%#v", result.SkillTags)
	}
	if result.PreferenceConfigured {
		t.Fatal("无偏好记录时不得标记为已配置")
	}
}
