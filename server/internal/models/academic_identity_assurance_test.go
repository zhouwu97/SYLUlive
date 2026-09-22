package models

import (
	"testing"
	"time"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

// TestTrustedAcademicBindingScopeMatchesGoPredicate 锁住 SQL 判权与 Go 判权的一致性：
// 两处规则一旦分叉，就会出现"查询认为可信、响应认为不可信"的身份。
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
	}
	now := time.Now()
	for i, method := range methods {
		if err := db.Create(&AcademicIdentityBinding{
			UserID: uint(900 + i), ProviderID: AcademicProviderUndergraduate,
			StudentID: "240801000" + string(rune('0'+i)), VerifiedAt: now,
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
		t.Fatalf("可信身份查询未过滤本机声明: %d/%d", len(bindings), len(methods))
	}
	trustedByUser := make(map[uint]string, len(bindings))
	for _, binding := range bindings {
		trustedByUser[binding.UserID] = binding.VerificationMethod
	}
	for i, method := range methods {
		userID := uint(900 + i)
		_, inSQL := trustedByUser[userID]
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
}
