package handlers

import (
	"mime"
	"strings"
	"testing"
)

func TestBuildVerifyCodeEmailUsesUTF8HeadersAndReadableBody(t *testing.T) {
	message := string(buildVerifyCodeEmail("3170305904@qq.com", "noreply@example.com", "987316"))

	for _, want := range []string{
		"Content-Type: text/html; charset=UTF-8",
		"Content-Transfer-Encoding: 8bit",
		"<meta charset=\"UTF-8\">",
		"10 分钟",
		"987316",
	} {
		if !strings.Contains(message, want) {
			t.Fatalf("message missing %q:\n%s", want, message)
		}
	}

	for _, bad := range []string{"鍒嗛挓", "乱码"} {
		if strings.Contains(message, bad) {
			t.Fatalf("message contains mojibake marker %q:\n%s", bad, message)
		}
	}

	wantSubject := "Subject: " + mime.QEncoding.Encode("UTF-8", "沈理校园注册验证码")
	if !strings.Contains(message, wantSubject) {
		t.Fatalf("subject is not MIME encoded, want header %q:\n%s", wantSubject, message)
	}
}
