package handlers

import (
	"errors"
	"net/http"
	"testing"
)

func TestClassifyAcademicIdentityFailureFailsClosedForAmbiguousResponses(t *testing.T) {
	if err := ClassifyAcademicIdentityFailure(http.StatusUnauthorized, "INVALID_CREDENTIALS", "用户名或密码错误"); !errors.Is(err, ErrAcademicAuthRejectedAmbiguous) {
		t.Fatalf("模糊认证响应分类=%v，期望 ambiguous", err)
	}
	if err := classifyAcademicIdentityFailure(http.StatusUnauthorized, "", "密码错误"); !errors.Is(err, ErrAcademicCredentialRejected) {
		t.Fatalf("明确密码错误分类=%v，期望 credential rejected", err)
	}
	if err := ClassifyAcademicIdentityFailure(http.StatusUnauthorized, "", "验证码错误"); !errors.Is(err, ErrAcademicChallengeRejected) {
		t.Fatalf("明确验证码错误分类=%v，期望 challenge rejected", err)
	}
	if err := ClassifyAcademicIdentityFailure(http.StatusUnauthorized, "", "请检查账号、密码或验证码"); !errors.Is(err, ErrAcademicAuthRejectedAmbiguous) {
		t.Fatalf("含密码字样的模糊响应分类=%v，期望 ambiguous", err)
	}
}

func TestClassifyAcademicIdentityFailureKeepsTransportFailuresSeparate(t *testing.T) {
	if err := ClassifyAcademicIdentityFailure(http.StatusTooManyRequests, "", "请求失败"); !errors.Is(err, ErrAcademicRateLimited) {
		t.Fatalf("限流响应分类=%v，期望 rate limited", err)
	}
	if err := ClassifyAcademicIdentityFailure(http.StatusBadGateway, "", "学校暂时不可用"); !errors.Is(err, ErrAcademicProviderUnavailable) {
		t.Fatalf("上游故障分类=%v，期望 provider unavailable", err)
	}
}

func TestClassifyAcademicIdentityFailurePreservesUndergraduateProfileErrors(t *testing.T) {
	if err := ClassifyAcademicIdentityFailure(http.StatusOK, "EDU_IDENTITY_UNVERIFIED", "学校未返回独立学号"); !errors.Is(err, ErrAcademicIdentityUnverified) {
		t.Fatalf("本科缺少学校学号分类=%v，期望 identity unverified", err)
	}
	if err := ClassifyAcademicIdentityFailure(http.StatusOK, "EDU_IDENTITY_MISMATCH", "学校学号不一致"); !errors.Is(err, ErrAcademicIdentityMismatch) {
		t.Fatalf("本科学校学号不一致分类=%v，期望 identity mismatch", err)
	}
}

func TestUndergraduateDiagnosticCodePreservesPythonCrawlerCodes(t *testing.T) {
	for _, code := range []string{
		"UNKNOWN_LOGIN_STATE", "SESSION_COOKIE_MISSING", "CAS_FLOW_CHANGED",
		"CSRF_MISSING", "PUBLIC_KEY_PARSE_ERROR", "INVALID_CREDENTIALS",
		"REMOTE_SYSTEM_UNAVAILABLE",
	} {
		if got := undergraduateDiagnosticCode(code); got != code {
			t.Fatalf("Python 教务错误码 %q 被诊断白名单折叠为 %q", code, got)
		}
	}
	if got := undergraduateDiagnosticCode("学校响应中的未知文本"); got != "OTHER" {
		t.Fatalf("未知错误码被原样写入诊断=%q，期望 OTHER", got)
	}
}
