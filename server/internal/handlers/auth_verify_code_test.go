package handlers

import (
	"bytes"
	"encoding/base64"
	"io"
	"mime"
	"net/mail"
	"strings"
	"testing"
)

func TestBuildVerifyCodeEmailUsesUTF8HeadersAndReadableBody(t *testing.T) {
	message := string(buildVerifyCodeEmail("3170305904@qq.com", "noreply@example.com", "987316"))
	parsed, err := mail.ReadMessage(strings.NewReader(message))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, parsed.Body))
	if err != nil {
		t.Fatal(err)
	}

	for _, want := range []string{
		"Content-Type: text/html; charset=UTF-8",
		"Content-Transfer-Encoding: base64",
	} {
		if !strings.Contains(message, want) {
			t.Fatalf("message missing %q:\n%s", want, message)
		}
	}
	for _, want := range []string{"<meta charset=\"UTF-8\">", "10 分钟", "987316"} {
		if !bytes.Contains(decoded, []byte(want)) {
			t.Fatalf("decoded body missing %q", want)
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
