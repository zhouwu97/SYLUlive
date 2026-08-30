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

func TestIsStableEduStateErrorCodePassesNewRefreshCodesThrough(t *testing.T) {
	stable := []string{
		"EDU_AUTHORIZATION_REVOKED", "EDU_SESSION_LOGGED_OUT", "EDU_SESSION_EXPIRED", "EDU_CREDENTIAL_UNAVAILABLE",
		"EDU_INVALID_CREDENTIALS", "EDU_UPSTREAM_UNAVAILABLE", "EDU_NETWORK_ERROR",
	}
	for _, code := range stable {
		if !isStableEduStateErrorCode(code) {
			t.Fatalf("code %s must pass through unchanged", code)
		}
	}
	for _, code := range []string{"", "EDU_FETCH_FAILED", "EDU_LOGIN_FAILED", "rag_unavailable"} {
		if isStableEduStateErrorCode(code) {
			t.Fatalf("code %s must not be treated as stable", code)
		}
	}
}
