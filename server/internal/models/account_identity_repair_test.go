package models

import (
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestRepairLegacyAccountIdentityStateRestoresHistoricalAccount(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:legacy-account-repair?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&User{}); err != nil {
		t.Fatal(err)
	}

	createdAt := time.Date(2026, 6, 1, 8, 0, 0, 0, time.Local)
	legacy := User{
		StudentID:       "2508030119",
		PasswordHash:    "hash",
		EduStudentID:    "2508030119",
		EduBound:        true,
		EduSessionState: "unbound",
		CreatedAt:       createdAt,
	}
	if err := db.Create(&legacy).Error; err != nil {
		t.Fatal(err)
	}

	report, err := RepairLegacyAccountIdentityState(db)
	if err != nil {
		t.Fatal(err)
	}
	if report.VerifiedStudents != 1 || report.RestoredAuthorizations != 1 {
		t.Fatalf("修复数量不符合预期: %+v", report)
	}

	var repaired User
	if err := db.First(&repaired, legacy.ID).Error; err != nil {
		t.Fatal(err)
	}
	if repaired.StudentVerifiedAt == nil || !repaired.StudentVerifiedAt.Equal(createdAt) {
		t.Fatalf("学生身份未恢复: %+v", repaired.StudentVerifiedAt)
	}
	if !repaired.EduAuthorized || !repaired.EduBound || repaired.EduSessionState != "active" ||
		repaired.EduAuthorizationGeneration != 1 || repaired.EduBindingState != "active" {
		t.Fatalf("教务授权未恢复: %+v", repaired)
	}

	second, err := RepairLegacyAccountIdentityState(db)
	if err != nil {
		t.Fatal(err)
	}
	if second.VerifiedStudents != 0 || second.RestoredAuthorizations != 0 {
		t.Fatalf("重复执行不应再次修改数据: %+v", second)
	}
}

func TestRepairLegacyAccountIdentityStateDoesNotInventIdentityOrConsent(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:legacy-account-repair-guard?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&User{}, &UserLegalConsent{}); err != nil {
		t.Fatal(err)
	}

	now := time.Now()
	users := []User{
		{StudentID: "2350016823", QQ: "2350016823", PasswordHash: "hash"},
		{StudentID: "2508030120", EduStudentID: "2508030120", EduBound: true, LegalConsentRevokedAt: &now, PasswordHash: "hash"},
		{StudentID: "2508030121", PasswordHash: "hash"},
	}
	if err := db.Create(&users).Error; err != nil {
		t.Fatal(err)
	}

	report, err := RepairLegacyAccountIdentityState(db)
	if err != nil {
		t.Fatal(err)
	}
	if report.VerifiedStudents != 2 || report.RestoredAuthorizations != 0 {
		t.Fatalf("保护条件失效: %+v", report)
	}

	var qqUser User
	if err := db.First(&qqUser, users[0].ID).Error; err != nil {
		t.Fatal(err)
	}
	if qqUser.StudentVerifiedAt != nil || qqUser.EduAuthorized {
		t.Fatalf("QQ 账号不应被推断为学生身份: %+v", qqUser)
	}

	var revoked User
	if err := db.First(&revoked, users[1].ID).Error; err != nil {
		t.Fatal(err)
	}
	if revoked.StudentVerifiedAt == nil || revoked.EduAuthorized {
		t.Fatalf("撤销授权账号应只恢复稳定学生身份: %+v", revoked)
	}

	var historicalStudent User
	if err := db.First(&historicalStudent, users[2].ID).Error; err != nil {
		t.Fatal(err)
	}
	if historicalStudent.StudentVerifiedAt == nil || historicalStudent.EduAuthorized {
		t.Fatalf("无 QQ 的历史学号应恢复登录身份，但不得推断教务授权: %+v", historicalStudent)
	}

	var consentCount int64
	if err := db.Model(&UserLegalConsent{}).Count(&consentCount).Error; err != nil {
		t.Fatal(err)
	}
	if consentCount != 0 {
		t.Fatalf("修复不得创建法律同意记录: %d", consentCount)
	}
}
