package handlers

import (
	"encoding/base64"
	"io"
	"mime"
	"net/http/httptest"
	"net/mail"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestPollParamIDRejectsNativeOverflow(t *testing.T) {
	for _, raw := range []string{"1", "4294967297", "18446744073709551615", "18446744073709551616", "0", "-1", "bad"} {
		t.Run(raw, func(t *testing.T) {
			c, _ := gin.CreateTestContext(httptest.NewRecorder())
			c.Params = gin.Params{{Key: "id", Value: raw}}
			want, err := strconv.ParseUint(raw, 10, strconv.IntSize)
			id, ok := pollParamID(c)
			if ok != (err == nil && want > 0) || (ok && uint64(id) != want) {
				t.Fatalf("id=%d ok=%v; parsed=%d err=%v", id, ok, want, err)
			}
		})
	}
}

func TestFeedbackRejectsInjectedAddressHeaders(t *testing.T) {
	for _, address := range []string{"user@example.com\r\nBcc: attacker@example.com", "user@example.com\nX-Test: injected", "user@example.com\x00"} {
		if _, err := buildFeedbackEmail(t.TempDir(), address, "from@example.com", "反馈", "<p>hello</p>", nil); err == nil {
			t.Fatalf("accepted injected recipient %q", address)
		}
		if _, err := buildFeedbackEmail(t.TempDir(), "to@example.com", address, "反馈", "<p>hello</p>", nil); err == nil {
			t.Fatalf("accepted injected sender %q", address)
		}
	}
}

func TestVerifyCodeEmailEscapesHTML(t *testing.T) {
	message := string(buildVerifyCodeEmail("to@example.com", "from@example.com", "<img src=x onerror=alert(1)>"))
	parsed, err := mail.ReadMessage(strings.NewReader(message))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, parsed.Body))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(decoded), "<img src=x") || !strings.Contains(string(decoded), "&lt;img") {
		t.Fatal("verification code is interpreted as HTML")
	}
}

func TestGraduateEndpointRejectsInjectedSessionPrefix(t *testing.T) {
	base, _ := url.Parse("https://yjsgl.sylu.edu.cn")
	provider := &GraduateAcademicIdentityProvider{baseURL: base}
	for _, prefix := range []string{"//attacker.example", "/?next=https://attacker.example", "/../admin", "/(S(test))/../admin", "/(S(test))#fragment"} {
		if endpoint := provider.endpointWithPrefix(prefix, "/home/stulogin_do"); endpoint != "" {
			t.Fatalf("accepted prefix %q: %s", prefix, endpoint)
		}
	}
}

func TestFeedbackDynamicSubjectAndBodyCannotAddMIMEParts(t *testing.T) {
	subject := "反馈\r\nBcc: evil@example.com"
	body := "<p>中文反馈</p>\r\n.\r\nBcc: evil@example.com\r\n--injected"
	raw, err := buildFeedbackEmail(t.TempDir(), "to@example.com", "from@example.com", subject, body, nil)
	if err != nil {
		t.Fatal(err)
	}
	message, parts := parseFeedbackMessage(t, raw)
	if message.Header.Get("Bcc") != "" {
		t.Fatal("injected Bcc header")
	}
	decodedSubject, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
	if err != nil || decodedSubject != subject {
		t.Fatalf("subject corrupted: %q %v", decodedSubject, err)
	}
	part, err := parts.NextRawPart()
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, part))
	if err != nil || string(decoded) != body {
		t.Fatalf("body corrupted: %q %v", decoded, err)
	}
	if _, err := parts.NextRawPart(); err != io.EOF {
		t.Fatalf("unexpected extra MIME part: %v", err)
	}
}
