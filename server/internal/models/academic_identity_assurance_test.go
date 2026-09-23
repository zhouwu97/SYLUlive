package models

import (
	"fmt"
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

// paddedVariants 返回同一可信方式的带空白变体。
//
// 这些必须在 Go 与 SQL 两侧得到**相同**结论；旧实现 Go 判权前 Trim、SQL 直接比原值，
// 于是带换行的 legacy_migration 在 Go 侧可信、在 SQL 侧不可信。
func paddedVariants(method string) []string {
	return []string{
		" " + method,
		method + " ",
		"\t" + method + "\n",
		"\n" + method + "\t",
	}
}

// TestIsTrustedAcademicVerificationMethodIsAllowlist 锁住「默认不信任」：
// 未登记取值一旦被判为可信，任何历史脏数据或未来新增字段都能提权。
func TestIsTrustedAcademicVerificationMethodIsAllowlist(t *testing.T) {
	for _, method := range []string{
		AcademicVerificationMethodSchoolProfile,
		AcademicVerificationMethodLegacyMigration,
	} {
		if !IsTrustedAcademicVerificationMethod(method) {
			t.Errorf("已登记的可信方式 %q 未被判为可信", method)
		}
	}
	untrusted := []string{
		"",
		"   ",
		AcademicVerificationMethodLocalDeclaration,
		// 未登记取值：旧实现用排除名单，这些都会被当成可信。
		"test",
		"fixture",
		"school_profile_v2",
		"SCHOOL_PROFILE",
		"unknown",
	}
	for _, method := range paddedVariants(AcademicVerificationMethodSchoolProfile) {
		untrusted = append(untrusted, method)
	}
	for _, method := range paddedVariants(AcademicVerificationMethodLegacyMigration) {
		untrusted = append(untrusted, method)
	}
	for _, method := range untrusted {
		if IsTrustedAcademicVerificationMethod(method) {
			t.Errorf("未登记/不可信方式 %q 被判为可信", method)
		}
	}
	for _, method := range []string{
		"",
		"   ",
		"test",
		"school_profile_v2",
		" school_profile",
		"school_profile ",
	} {
		if !IsUnregisteredAcademicVerificationMethod(method) {
			t.Errorf("脏数据 %q 未被盘点助手标记为未登记", method)
		}
	}
	// 本机声明是登记过但不授予可信身份的正常状态，不能算脏数据。
	if IsUnregisteredAcademicVerificationMethod(AcademicVerificationMethodLocalDeclaration) {
		t.Error("本机声明被误判为未登记脏数据")
	}
}

// TestValidateAcademicVerificationMethodRejectsUnknownAndPadded 锁住写入规范：
// 判权用精确匹配，写入侧就该拒绝产生带空白或未登记的记录。
func TestValidateAcademicVerificationMethodRejectsUnknownAndPadded(t *testing.T) {
	for _, method := range []string{
		AcademicVerificationMethodSchoolProfile,
		AcademicVerificationMethodLegacyMigration,
		AcademicVerificationMethodLocalDeclaration,
	} {
		if err := ValidateAcademicVerificationMethod(method); err != nil {
			t.Errorf("登记过的核验方式 %q 被写入规范拒绝: %v", method, err)
		}
	}
	rejected := []string{"", " ", " test ", "school_profile_v2", "SCHOOL_PROFILE"}
	for _, method := range paddedVariants(AcademicVerificationMethodSchoolProfile) {
		rejected = append(rejected, method)
	}
	for _, method := range rejected {
		if err := ValidateAcademicVerificationMethod(method); err == nil {
			t.Errorf("写入规范放过了非法核验方式 %q", method)
		}
	}
}

// TestAcademicIdentityBindingValidateEnforcesMethod 锁住模型边界同样约束核验方式，
// 避免绕过 handler 直接写入不受支持的依据来源。
func TestAcademicIdentityBindingValidateEnforcesMethod(t *testing.T) {
	base := AcademicIdentityBinding{
		UserID: 7, ProviderID: AcademicProviderUndergraduate, StudentID: "2408010001",
		VerifiedAt: time.Now(), VerificationVersion: "v1",
	}
	for _, method := range append([]string{"", "test", "unregistered"},
		paddedVariants(AcademicVerificationMethodSchoolProfile)...) {
		binding := base
		binding.VerificationMethod = method
		if err := binding.Validate(); err == nil {
			t.Errorf("Validate 放过了非法核验方式 %q", method)
		}
	}
	binding := base
	binding.VerificationMethod = AcademicVerificationMethodSchoolProfile
	if err := binding.Validate(); err != nil {
		t.Fatalf("合法绑定被拒绝: %v", err)
	}
}

// TestTrustedAcademicBindingScopeMatchesGoPredicate 锁住 SQL 判权与 Go 判权的一致性：
// 两处规则一旦分叉，就会出现"查询认为可信、响应认为不可信"的身份。
// 覆盖未登记取值与空白变体——旧实现正是这两类在 Go 与 SQL 之间结论相反。
func TestTrustedAcademicBindingScopeMatchesGoPredicate(t *testing.T) {
	db, err := gorm.Open(sqlite.Open("file:academic-assurance-scope?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&AcademicIdentityBinding{}); err != nil {
		t.Fatal(err)
	}
	methods := []string{
		AcademicVerificationMethodSchoolProfile,
		AcademicVerificationMethodLegacyMigration,
		AcademicVerificationMethodLocalDeclaration,
		"",
		"  ",
		"test",
		"school_profile_v2",
	}
	methods = append(methods, paddedVariants(AcademicVerificationMethodSchoolProfile)...)
	methods = append(methods, paddedVariants(AcademicVerificationMethodLegacyMigration)...)
	now := time.Now()
	for i, method := range methods {
		if err := db.Create(&AcademicIdentityBinding{
			UserID: uint(900 + i), ProviderID: AcademicProviderUndergraduate,
			StudentID: fmt.Sprintf("240801%04d", i), VerifiedAt: now,
			VerificationMethod: method, VerificationVersion: "v1",
		}).Error; err != nil {
			t.Fatal(err)
		}
	}

	var bindings []AcademicIdentityBinding
	if err := TrustedAcademicBindingScope(db.Where("verified_at > ?", time.Time{})).
		Order("user_id ASC").Find(&bindings).Error; err != nil {
		t.Fatal(err)
	}
	if len(bindings) == 0 || len(bindings) == len(methods) {
		t.Fatalf("可信身份查询未过滤本机声明与未登记取值: %d/%d", len(bindings), len(methods))
	}
	trustedByUser := make(map[uint]bool, len(bindings))
	for _, binding := range bindings {
		trustedByUser[binding.UserID] = true
	}
	for i, method := range methods {
		userID := uint(900 + i)
		inSQL := trustedByUser[userID]
		if inSQL != IsTrustedAcademicVerificationMethod(method) {
			t.Errorf("方法 %q 的 SQL 判定 %v 与 Go 判定 %v 不一致", method, inSQL, IsTrustedAcademicVerificationMethod(method))
		}
	}
}

func TestAcademicAssuranceLevelNaming(t *testing.T) {
	if got := AcademicAssuranceLevel(AcademicVerificationMethodLocalDeclaration); got != AcademicAssuranceLocalDeclaration {
		t.Fatalf("本机声明的依据强度 = %q", got)
	}
	if got := AcademicAssuranceLevel(AcademicVerificationMethodSchoolProfile); got != AcademicAssuranceSchoolVerified {
		t.Fatalf("学校核验的依据强度 = %q", got)
	}
	if got := AcademicAssuranceLevel(AcademicVerificationMethodLegacyMigration); got != AcademicAssuranceLegacyInherited {
		t.Fatalf("历史回填身份的依据强度 = %q", got)
	}
	if got := AcademicAssuranceLevel("test"); got != AcademicAssuranceLocalDeclaration {
		t.Fatalf("未登记方式的依据强度 = %q，未登记不能称作学校核验", got)
	}
}
