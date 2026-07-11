package handlers

import "testing"

func TestClassifyEduLoginFailureOnlyUsesCredentialCodeForExplicitPasswordErrors(t *testing.T) {
	credentialMessages := []string{
		"用户名或密码错误",
		"用户名或密码不正确，请重新输入！",
	}
	for _, message := range credentialMessages {
		err := classifyEduLoginFailure(200, message)
		loginErr, ok := err.(*eduLoginError)
		if !ok {
			t.Fatalf("message=%q got %T, want *eduLoginError", message, err)
		}
		if loginErr.Code != "INVALID_CREDENTIALS" {
			t.Fatalf("message=%q code=%s want INVALID_CREDENTIALS", message, loginErr.Code)
		}
	}

	err := classifyEduLoginFailure(200, "<html><title>统一认证</title></html>")
	loginErr, ok := err.(*eduLoginError)
	if !ok {
		t.Fatalf("got %T, want *eduLoginError", err)
	}
	if loginErr.Code == "INVALID_CREDENTIALS" {
		t.Fatalf("unknown login page must not be classified as credentials error")
	}
}
