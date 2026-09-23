package models

import (
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func openIdentityInventoryDB(t *testing.T) *gorm.DB {
	t.Helper()
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&AcademicIdentityBinding{}); err != nil {
		t.Fatal(err)
	}
	return db
}

func insertInventoryBinding(t *testing.T, db *gorm.DB, binding AcademicIdentityBinding) {
	t.Helper()
	if binding.VerifiedAt.IsZero() {
		binding.VerifiedAt = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	if binding.ProviderID == "" {
		binding.ProviderID = "jwxt-undergraduate"
	}
	if binding.VerificationVersion == "" {
		binding.VerificationVersion = "v1"
	}
	if err := db.Create(&binding).Error; err != nil {
		t.Fatalf("插入测试绑定失败（%s / %s / %s）: %v",
			binding.VerificationMethod, binding.StudentID, binding.ProviderID, err)
	}
}

// 盘点必须把「库里实际存了什么」和「判权认什么」分开报出来：
// legacy_migration 的真实规模决定它能不能继续留在可信白名单里。
func TestReadAcademicIdentityVerificationInventorySplitsTrustLevels(t *testing.T) {
	db := openIdentityInventoryDB(t)
	for _, binding := range []AcademicIdentityBinding{
		{UserID: 1, StudentID: "S1", VerificationMethod: AcademicVerificationMethodSchoolProfile},
		{UserID: 2, StudentID: "S2", VerificationMethod: AcademicVerificationMethodSchoolProfile},
		{UserID: 3, StudentID: "S3", VerificationMethod: AcademicVerificationMethodLegacyMigration},
		{UserID: 4, StudentID: "S4", VerificationMethod: AcademicVerificationMethodLocalDeclaration},
		{UserID: 5, StudentID: "S5", VerificationMethod: "unknown_method"},
		{UserID: 6, StudentID: "S6", VerificationMethod: " " + AcademicVerificationMethodLegacyMigration},
	} {
		insertInventoryBinding(t, db, binding)
	}

	inventory, err := ReadAcademicIdentityVerificationInventory(db)
	if err != nil {
		t.Fatal(err)
	}
	if inventory.Total != 6 {
		t.Fatalf("total = %d", inventory.Total)
	}
	if inventory.SchoolVerified != 2 || inventory.LegacyInherited != 1 || inventory.LocalDeclaration != 1 {
		t.Fatalf("分类错误: school=%d legacy=%d local=%d",
			inventory.SchoolVerified, inventory.LegacyInherited, inventory.LocalDeclaration)
	}
	// 带空白的 legacy_migration 不在判权白名单里（精确匹配），因此既不算可信
	// 也不该被并进 legacy_migration 计数——它必须以未登记脏值的身份暴露出来。
	if inventory.TrustedTotal != 3 {
		t.Fatalf("trusted_total = %d，期望 3（带空白变体不得算可信）", inventory.TrustedTotal)
	}
	if inventory.Unregistered != 2 {
		t.Fatalf("unregistered = %d，期望 2", inventory.Unregistered)
	}
	if len(inventory.UnregisteredMethods) != 2 {
		t.Fatalf("unregistered_methods = %v", inventory.UnregisteredMethods)
	}
	if inventory.MethodWhitespaceDirty != 1 {
		t.Fatalf("method_whitespace_dirty = %d", inventory.MethodWhitespaceDirty)
	}
	if inventory.ByMethod["unknown_method"] != 1 {
		t.Fatalf("by_method = %v", inventory.ByMethod)
	}
	if inventory.SharedStudentIDs != 0 || inventory.MultiStudentAccounts != 0 {
		t.Fatalf("正常数据不应报关系异常: %d / %d", inventory.SharedStudentIDs, inventory.MultiStudentAccounts)
	}
}

// 跨提供方的同名学号不能误判为共享；一号多学号仍是人工核对的直接线索。
func TestReadAcademicIdentityVerificationInventoryCountsRelationAnomalies(t *testing.T) {
	db := openIdentityInventoryDB(t)
	for _, binding := range []AcademicIdentityBinding{
		// 不同提供方可能使用相同学号，不能把它算成共享身份。
		{UserID: 1, StudentID: "SHARED", VerificationMethod: AcademicVerificationMethodSchoolProfile},
		{UserID: 2, StudentID: "SHARED", VerificationMethod: AcademicVerificationMethodLegacyMigration},
		// 同一账号挂了两个学号。
		{UserID: 3, StudentID: "A1", VerificationMethod: AcademicVerificationMethodSchoolProfile},
		{UserID: 3, StudentID: "A2", VerificationMethod: AcademicVerificationMethodLegacyMigration},
	} {
		// 唯一约束和身份语义都以提供方为边界。
		binding.ProviderID = "provider-" + binding.StudentID + "-" + string(rune('0'+int(binding.UserID)))
		insertInventoryBinding(t, db, binding)
	}

	inventory, err := ReadAcademicIdentityVerificationInventory(db)
	if err != nil {
		t.Fatal(err)
	}
	if inventory.SharedStudentIDs != 0 {
		t.Fatalf("跨提供方同名学号不应计为共享: %d", inventory.SharedStudentIDs)
	}
	if inventory.MultiStudentAccounts != 1 {
		t.Fatalf("multi_student_accounts = %d，期望 1", inventory.MultiStudentAccounts)
	}
}

// 缺验证时间的绑定必须单独计数：准入的最低事实都不完整。
func TestReadAcademicIdentityVerificationInventoryCountsMissingVerifiedAt(t *testing.T) {
	db := openIdentityInventoryDB(t)
	insertInventoryBinding(t, db, AcademicIdentityBinding{
		UserID: 1, StudentID: "S1",
		VerificationMethod: AcademicVerificationMethodSchoolProfile,
		VerifiedAt:         time.Unix(0, 0).UTC().Add(-time.Hour),
	})
	insertInventoryBinding(t, db, AcademicIdentityBinding{
		UserID: 2, StudentID: "S2",
		VerificationMethod: AcademicVerificationMethodSchoolProfile,
	})

	inventory, err := ReadAcademicIdentityVerificationInventory(db)
	if err != nil {
		t.Fatal(err)
	}
	if inventory.MissingVerifiedAt != 1 {
		t.Fatalf("missing_verified_at = %d，期望 1", inventory.MissingVerifiedAt)
	}
}

// 本机声明不得被算进可信规模：它从来不授予准入。
func TestReadAcademicIdentityVerificationInventoryNeverCountsLocalDeclarationAsTrusted(t *testing.T) {
	db := openIdentityInventoryDB(t)
	for i := 1; i <= 4; i++ {
		insertInventoryBinding(t, db, AcademicIdentityBinding{
			UserID: uint(i), StudentID: "L" + string(rune('0'+i)),
			VerificationMethod: AcademicVerificationMethodLocalDeclaration,
		})
	}
	inventory, err := ReadAcademicIdentityVerificationInventory(db)
	if err != nil {
		t.Fatal(err)
	}
	if inventory.TrustedTotal != 0 || inventory.LocalDeclaration != 4 {
		t.Fatalf("trusted_total=%d local_declaration=%d", inventory.TrustedTotal, inventory.LocalDeclaration)
	}
}
