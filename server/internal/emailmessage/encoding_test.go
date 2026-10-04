package emailmessage

import (
	"encoding/base64"
	"mime"
	"strings"
	"testing"
)

func TestHeaderAndBodyRoundTrip(t *testing.T) {
	text := strings.Repeat("中文反馈 😀\r\nBcc: injected@example.com", 20)
	decoded, err := new(mime.WordDecoder).DecodeHeader(Subject(text))
	if err != nil || decoded != text {
		t.Fatalf("subject round trip: %q %v", decoded, err)
	}
	for _, word := range strings.Fields(Subject(text)) {
		if len(word) > 75 {
			t.Fatal("oversized encoded word")
		}
	}
	raw, err := base64.StdEncoding.DecodeString(Body([]byte(text)))
	if err != nil || string(raw) != text {
		t.Fatalf("body round trip: %v", err)
	}
	for _, line := range strings.Split(Body([]byte(text)), "\r\n") {
		if len(line) > 76 || strings.ContainsAny(line, ":<>-") {
			t.Fatalf("invalid MIME body line %q", line)
		}
	}
}

func TestAddressHeaderRejectsControlCharacters(t *testing.T) {
	for _, bad := range []string{"to@example.com\r\nBcc: evil@example.com", "to@example.com\x00", "invalid"} {
		if _, err := AddressHeader(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
	if header, err := AddressHeader("沈理校园 <sender@example.com>"); err != nil || strings.ContainsAny(header, "\r\n") {
		t.Fatalf("valid address: %q %v", header, err)
	}
}
