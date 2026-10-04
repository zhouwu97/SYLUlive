// Package emailmessage frames dynamic email content without allowing it to
// introduce SMTP headers or MIME boundaries.
package emailmessage

import (
	"encoding/base64"
	"errors"
	"net/mail"
	"strings"
)

func AddressHeader(value string) (string, error) {
	for _, r := range value {
		if r < 32 || r == 127 {
			return "", errors.New("invalid control character in email address")
		}
	}
	address, err := mail.ParseAddress(value)
	if err != nil {
		return "", err
	}
	return address.String(), nil
}

// Subject uses RFC 2047 encoded words of at most 72 characters. Splitting at
// rune boundaries preserves UTF-8; only generated folding adds line breaks.
func Subject(value string) string {
	var words []string
	var chunk strings.Builder
	flush := func() {
		words = append(words, "=?UTF-8?B?"+base64.StdEncoding.EncodeToString([]byte(chunk.String()))+"?=")
		chunk.Reset()
	}
	for _, r := range value {
		if chunk.Len()+len(string(r)) > 45 {
			flush()
		}
		chunk.WriteRune(r)
	}
	if chunk.Len() > 0 {
		flush()
	}
	return strings.Join(words, "\r\n ")
}

// Body uses RFC 2045 base64 so dynamic text cannot supply a MIME delimiter.
func Body(value []byte) string {
	encoded := base64.StdEncoding.EncodeToString(value)
	var out strings.Builder
	for len(encoded) > 76 {
		out.WriteString(encoded[:76])
		out.WriteString("\r\n")
		encoded = encoded[76:]
	}
	out.WriteString(encoded)
	return out.String()
}
