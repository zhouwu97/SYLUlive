package handlers

import (
	"bytes"
	"encoding/base64"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"shenliyuan/internal/models"
)

// parseFeedbackMessage 把 buildFeedbackEmail 的输出拆成顶层消息与 multipart 部件读取器。
func parseFeedbackMessage(t *testing.T, msg []byte) (*mail.Message, *multipart.Reader) {
	t.Helper()
	m, err := mail.ReadMessage(bytes.NewReader(msg))
	if err != nil {
		t.Fatal(err)
	}
	mediaType, params, err := mime.ParseMediaType(m.Header.Get("Content-Type"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(mediaType, "multipart/") {
		t.Fatalf("expected multipart Content-Type, got %q", mediaType)
	}
	return m, multipart.NewReader(m.Body, params["boundary"])
}

func TestBuildFeedbackEmailQuotedPrintableBody(t *testing.T) {
	body := "🐛 Bug 反馈\n中文内容：用户昵称 联系方式\n📎 附图"
	msg, err := buildFeedbackEmail(t.TempDir(), "to@example.com", "from@example.com", "【沈理校园反馈】来自 测试用户", body, nil)
	if err != nil {
		t.Fatal(err)
	}
	// NextRawPart 不隐藏/不自动解码 Content-Transfer-Encoding，可同时断言编码头与手动 QP 解码。
	_, mr := parseFeedbackMessage(t, msg)
	var htmlBody string
	for {
		part, err := mr.NextRawPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasPrefix(part.Header.Get("Content-Type"), "text/html") {
			if enc := part.Header.Get("Content-Transfer-Encoding"); enc != "quoted-printable" {
				t.Fatalf("HTML part should declare quoted-printable, got %q", enc)
			}
			decoded, err := io.ReadAll(quotedprintable.NewReader(part))
			if err != nil {
				t.Fatal(err)
			}
			htmlBody = string(decoded)
		}
	}
	// QP 编码器按 RFC 2045 使用 CRLF 换行，比较前归一化。
	normalized := strings.ReplaceAll(htmlBody, "\r\n", "\n")
	if normalized != body {
		t.Fatalf("QP body mismatch:\n got %q\nwant %q", normalized, body)
	}
}

func TestBuildFeedbackEmailRelatedWithMatchingCids(t *testing.T) {
	uploadDir := t.TempDir()
	for _, name := range []string{"shot1.png", "shot2.jpg"} {
		if err := os.WriteFile(filepath.Join(uploadDir, name), []byte("fake-image-"+name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	files := []models.File{
		{Path: "/uploads/shot1.png", MimeType: "image/png"},
		{Path: "/uploads/shot2.jpg", MimeType: "image/jpeg"},
	}
	body := `<html><body><img src="cid:feedback-image-1" /><img src="cid:feedback-image-2" /></body></html>`
	msg, err := buildFeedbackEmail(uploadDir, "to@example.com", "from@example.com", "subject", body, files)
	if err != nil {
		t.Fatal(err)
	}
	m, mr := parseFeedbackMessage(t, msg)
	if mediaType, _, err := mime.ParseMediaType(m.Header.Get("Content-Type")); err != nil || mediaType != "multipart/related" {
		t.Fatalf("expected multipart/related, got %q (err=%v)", mediaType, err)
	}
	cidSet := map[string]bool{}
	var htmlBody string
	for {
		part, err := mr.NextRawPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if cid := part.Header.Get("Content-ID"); cid != "" {
			key := strings.Trim(cid, "<>")
			if cidSet[key] {
				t.Fatalf("duplicate Content-ID %q", cid)
			}
			cidSet[key] = true
		}
		if strings.HasPrefix(part.Header.Get("Content-Type"), "text/html") {
			decoded, err := io.ReadAll(quotedprintable.NewReader(part))
			if err != nil {
				t.Fatal(err)
			}
			htmlBody = string(decoded)
		}
	}
	re := regexp.MustCompile(`cid:([^"')\s]+)`)
	for _, ref := range re.FindAllStringSubmatch(htmlBody, -1) {
		if !cidSet[ref[1]] {
			t.Fatalf("HTML references cid %q but no matching MIME part exists", ref[1])
		}
	}
	if len(cidSet) != 2 {
		t.Fatalf("expected 2 unique image Content-IDs, got %v", cidSet)
	}
}

func TestBuildFeedbackEmailFailsWhenAttachmentUnavailable(t *testing.T) {
	uploadDir := t.TempDir()
	cases := []struct {
		name  string
		file  models.File
		check func(error) bool
	}{
		{
			name:  "file missing on disk",
			file:  models.File{Path: "/uploads/ghost.png", MimeType: "image/png"},
			check: func(err error) bool { return err != nil },
		},
		{
			name:  "path traversal rejected",
			file:  models.File{Path: "/uploads/../../etc/passwd", MimeType: "image/png"},
			check: func(err error) bool { return err != nil },
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := buildFeedbackEmail(uploadDir, "to@example.com", "from@example.com", "subject", "<html/>", []models.File{tc.file})
			if !tc.check(err) {
				t.Fatalf("expected attachment failure to fail the whole build, got nil")
			}
		})
	}
}

func TestBuildFeedbackEmailRejectsOversizedMessage(t *testing.T) {
	old := maxEmailMessageSize
	maxEmailMessageSize = 1024
	defer func() { maxEmailMessageSize = old }()

	body := "中文标题" + strings.Repeat("内容较长用来撑大邮件体积。", 400)
	if _, err := buildFeedbackEmail(t.TempDir(), "to@example.com", "from@example.com", "subject", body, nil); !errors.Is(err, errFeedbackEmailTooLarge) {
		t.Fatalf("expected errFeedbackEmailTooLarge, got %v", err)
	}
}

func TestBuildFeedbackEmailBase64WrapsAt76(t *testing.T) {
	uploadDir := t.TempDir()
	// 1041 字节（非 3 的倍数）覆盖末尾 padding 行。
	payload := make([]byte, 1041)
	for i := range payload {
		payload[i] = byte(i*31 + 7)
	}
	if err := os.WriteFile(filepath.Join(uploadDir, "img.png"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	msg, err := buildFeedbackEmail(uploadDir, "to@example.com", "from@example.com", "subject", "<html/>", []models.File{
		{Path: "/uploads/img.png", MimeType: "image/png"},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, mr := parseFeedbackMessage(t, msg)
	var encoded string
	for {
		part, err := mr.NextRawPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasPrefix(part.Header.Get("Content-Type"), "image/") {
			raw, err := io.ReadAll(part)
			if err != nil {
				t.Fatal(err)
			}
			encoded = string(raw)
		}
	}
	if encoded == "" {
		t.Fatal("no image part found")
	}
	for i, line := range strings.Split(encoded, "\r\n") {
		if line != "" && len(line) > 76 {
			t.Fatalf("base64 line %d exceeds 76 chars: %d", i, len(line))
		}
	}
	joined := strings.ReplaceAll(strings.ReplaceAll(encoded, "\r\n", ""), "\n", "")
	decoded, err := base64.StdEncoding.DecodeString(joined)
	if err != nil {
		t.Fatalf("decoding wrapped base64 failed: %v", err)
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatalf("decoded attachment mismatch: got %d bytes, want %d", len(decoded), len(payload))
	}
}
