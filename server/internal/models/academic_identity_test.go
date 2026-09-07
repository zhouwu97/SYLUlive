package models

import (
	"errors"
	"testing"
	"time"
)

func TestAcademicIdentityKeyRequiresRegisteredProviderAndOpaqueStudentID(t *testing.T) {
	graduateID := AcademicIdentityKey{AppUserID: 7, ProviderID: AcademicProviderSyluGraduate, StudentID: "G20260001"}
	if err := graduateID.Validate(); err != nil {
		t.Fatalf("研究生 opaque 学号应通过校验: %v", err)
	}
	undergraduateID := graduateID
	undergraduateID.ProviderID = AcademicProviderSyluUndergraduate
	if graduateID.Matches(undergraduateID) {
		t.Fatal("Provider 不同的相同学号不能视为同一身份")
	}
	if err := (AcademicIdentityKey{AppUserID: 7, ProviderID: AcademicProviderID("graduate"), StudentID: "G20260001"}).Validate(); !errors.Is(err, ErrInvalidAcademicProvider) {
		t.Fatalf("未知 Provider 错误=%v，期望 ErrInvalidAcademicProvider", err)
	}
}

func TestValidateAcademicStudentIDRejectsOnlyUnsafeShape(t *testing.T) {
	for _, value := range []string{"", " G20260001", "G20260001 ", "G\n20260001"} {
		if _, err := ValidateAcademicStudentID(value); !errors.Is(err, ErrInvalidAcademicStudentID) {
			t.Fatalf("学号 %q 应被拒绝，得到 %v", value, err)
		}
	}
	if _, err := ValidateAcademicStudentID("G2026-0001"); err != nil {
		t.Fatalf("合法的 Provider 内 opaque 学号被拒绝: %v", err)
	}
}

func TestAcademicIdentityBindingValidateRequiresVerifiedMetadata(t *testing.T) {
	binding := AcademicIdentityBinding{
		UserID: 7, ProviderID: AcademicProviderGraduate, StudentID: "G20260001",
		VerifiedAt: time.Now(), VerificationMethod: "school_profile", VerificationVersion: "v1",
	}
	if err := binding.Validate(); err != nil {
		t.Fatalf("完整身份绑定应通过校验: %v", err)
	}
	binding.VerificationVersion = ""
	if err := binding.Validate(); err == nil {
		t.Fatal("缺少验证版本的身份绑定不应通过校验")
	}
}
