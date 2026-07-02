package handlers

import "testing"

func TestClassifyEduLoginFailureOnlyUsesCredentialCodeForExplicitPasswordErrors(t *testing.T) {
	err := classifyEduLoginFailure(200, "用户名或密码错误")
	loginErr, ok := err.(*eduLoginError)
	if !ok {
		t.Fatalf("got %T, want *eduLoginError", err)
	}
	if loginErr.Code != "INVALID_CREDENTIALS" {
		t.Fatalf("code=%s want INVALID_CREDENTIALS", loginErr.Code)
	}

	err = classifyEduLoginFailure(200, "<html><title>统一认证</title></html>")
	loginErr, ok = err.(*eduLoginError)
	if !ok {
		t.Fatalf("got %T, want *eduLoginError", err)
	}
	if loginErr.Code == "INVALID_CREDENTIALS" {
		t.Fatalf("unknown login page must not be classified as credentials error")
	}
}
