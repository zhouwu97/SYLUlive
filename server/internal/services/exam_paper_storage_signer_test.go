package services

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func fixedStorageSignerNow() time.Time {
	return time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
}

func testStorageGrant() ExamPaperStorageGrant {
	now := fixedStorageSignerNow()
	return ExamPaperStorageGrant{
		Purpose:   ExamPaperStoragePurposeUpload,
		SessionID: "session-1",
		FileKey:   "papers/a.pdf",
		UserID:    42,
		PaperID:   7,
		Method:    "post",
		Path:      "/v1/papers/upload",
		IssuedAt:  now.Unix(),
		ExpiresAt: now.Add(10 * time.Minute).Unix(),
		JTI:       "jti-1",
	}
}

func testStorageReceipt() ExamPaperUploadReceipt {
	return ExamPaperUploadReceipt{
		SessionID: "session-1",
		FileKey:   "papers/a.pdf",
		FileSize:  123,
		SHA256:    strings.Repeat("a", 64),
		IssuedAt:  fixedStorageSignerNow().Unix(),
	}
}

func decodeStorageTokenPayload(t *testing.T, token string) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		t.Fatalf("token 段数错误: %d", len(parts))
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("解码 token payload 失败: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("解析 token payload 失败: %v", err)
	}
	return decoded
}

func TestExamPaperStorageSignerGrantRoundTrip(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("grant-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}

	token, err := signer.SignGrant(testStorageGrant())
	if err != nil {
		t.Fatalf("签发授权失败: %v", err)
	}
	got, err := signer.VerifyGrant(token, ExamPaperStoragePurposeUpload, "POST", "/v1/papers/upload")
	if err != nil {
		t.Fatalf("验证授权失败: %v", err)
	}
	if got.SessionID != "session-1" || got.FileKey != "papers/a.pdf" || got.Method != "POST" {
		t.Fatalf("授权内容不匹配: %#v", got)
	}
}

func TestExamPaperStorageSignerRejectsTamperedGrant(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("grant-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	token, err := signer.SignGrant(testStorageGrant())
	if err != nil {
		t.Fatalf("签发授权失败: %v", err)
	}
	if _, err := signer.VerifyGrant(token+"x", ExamPaperStoragePurposeUpload, "POST", "/v1/papers/upload"); !errors.Is(err, ErrStorageSignatureInvalid) {
		t.Fatalf("篡改授权错误不正确: %v", err)
	}
}

func TestExamPaperStorageSignerRejectsExpiredGrant(t *testing.T) {
	now := fixedStorageSignerNow()
	current := now
	signer, err := NewExamPaperStorageSigner("grant-secret", func() time.Time { return current })
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	token, err := signer.SignGrant(testStorageGrant())
	if err != nil {
		t.Fatalf("签发授权失败: %v", err)
	}
	current = now.Add(11 * time.Minute)
	if _, err := signer.VerifyGrant(token, ExamPaperStoragePurposeUpload, "POST", "/v1/papers/upload"); !errors.Is(err, ErrStorageGrantExpired) {
		t.Fatalf("过期授权错误不正确: %v", err)
	}
}

func TestExamPaperStorageSignerRejectsGrantScopeMismatch(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("grant-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	token, err := signer.SignGrant(testStorageGrant())
	if err != nil {
		t.Fatalf("签发授权失败: %v", err)
	}
	checks := []struct {
		name    string
		purpose string
		method  string
		path    string
	}{
		{name: "用途", purpose: ExamPaperStoragePurposeDownload, method: "POST", path: "/v1/papers/upload"},
		{name: "方法", purpose: ExamPaperStoragePurposeUpload, method: "GET", path: "/v1/papers/upload"},
		{name: "路径", purpose: ExamPaperStoragePurposeUpload, method: "POST", path: "/v1/papers/other"},
	}
	for _, check := range checks {
		t.Run(check.name, func(t *testing.T) {
			if _, err := signer.VerifyGrant(token, check.purpose, check.method, check.path); !errors.Is(err, ErrStorageSignatureInvalid) {
				t.Fatalf("范围不匹配错误不正确: %v", err)
			}
		})
	}
}

func TestExamPaperStorageSignerRejectsMalformedGrant(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("grant-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	if _, err := signer.VerifyGrant("malformed", ExamPaperStoragePurposeUpload, "POST", "/v1/papers/upload"); !errors.Is(err, ErrStorageSignatureInvalid) {
		t.Fatalf("格式错误不正确: %v", err)
	}
	if _, err := signer.VerifyGrant("***.***", ExamPaperStoragePurposeUpload, "POST", "/v1/papers/upload"); !errors.Is(err, ErrStorageSignatureInvalid) {
		t.Fatalf("非法 base64url 错误不正确: %v", err)
	}
}

func TestNewExamPaperStorageSignerRejectsEmptySecret(t *testing.T) {
	if _, err := NewExamPaperStorageSigner("", fixedStorageSignerNow); err == nil {
		t.Fatal("空密钥必须被拒绝")
	}
}

func TestExamPaperStorageSignerReceiptRoundTrip(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("receipt-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	receipt := testStorageReceipt()
	token, err := signer.SignReceipt(receipt)
	if err != nil {
		t.Fatalf("签发回执失败: %v", err)
	}
	got, err := signer.VerifyReceipt(token)
	if err != nil {
		t.Fatalf("验证回执失败: %v", err)
	}
	if got != receipt {
		t.Fatalf("回执内容不匹配: %#v", got)
	}
}

func TestExamPaperStorageSignerRejectsInvalidReceiptSemantics(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("receipt-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}

	tests := []struct {
		name    string
		receipt ExamPaperUploadReceipt
	}{
		{name: "零值回执", receipt: ExamPaperUploadReceipt{}},
		{name: "空会话", receipt: func() ExamPaperUploadReceipt { value := testStorageReceipt(); value.SessionID = " \t"; return value }()},
		{name: "空文件键", receipt: func() ExamPaperUploadReceipt { value := testStorageReceipt(); value.FileKey = " "; return value }()},
		{name: "文件大小为零", receipt: func() ExamPaperUploadReceipt { value := testStorageReceipt(); value.FileSize = 0; return value }()},
		{name: "文件大小为负", receipt: func() ExamPaperUploadReceipt { value := testStorageReceipt(); value.FileSize = -1; return value }()},
		{name: "摘要过短", receipt: func() ExamPaperUploadReceipt { value := testStorageReceipt(); value.SHA256 = "abc"; return value }()},
		{name: "摘要非十六进制", receipt: func() ExamPaperUploadReceipt {
			value := testStorageReceipt()
			value.SHA256 = strings.Repeat("z", 64)
			return value
		}()},
		{name: "签发时间为零", receipt: func() ExamPaperUploadReceipt { value := testStorageReceipt(); value.IssuedAt = 0; return value }()},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := signer.SignReceipt(tt.receipt); !errors.Is(err, ErrStorageReceiptInvalid) {
				t.Fatalf("签发无效回执错误不正确: %v", err)
			}
			token, err := signer.sign(tt.receipt)
			if err != nil {
				t.Fatalf("构造签名正确的测试回执失败: %v", err)
			}
			if _, err := signer.VerifyReceipt(token); !errors.Is(err, ErrStorageReceiptInvalid) {
				t.Fatalf("验签无效回执错误不正确: %v", err)
			}
		})
	}

	nullToken, err := signer.sign(nil)
	if err != nil {
		t.Fatalf("构造 null 测试回执失败: %v", err)
	}
	if _, err := signer.VerifyReceipt(nullToken); !errors.Is(err, ErrStorageReceiptInvalid) {
		t.Fatalf("null 回执错误不正确: %v", err)
	}
}

func TestExamPaperStorageReceiptUsesIssuedAtWireField(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("receipt-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	token, err := signer.SignReceipt(testStorageReceipt())
	if err != nil {
		t.Fatalf("签发回执失败: %v", err)
	}
	payload := decodeStorageTokenPayload(t, token)
	if _, ok := payload["issued_at"]; !ok {
		t.Fatal("回执 payload 必须包含 issued_at 字段")
	}
	if _, ok := payload["iat"]; ok {
		t.Fatal("回执 payload 不得包含 iat 字段")
	}
}

func TestExamPaperStorageSignerGrantAlwaysIncludesRequiredWireFields(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("grant-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建签名器失败: %v", err)
	}
	grant := testStorageGrant()
	grant.Method = ""
	grant.Path = ""
	grant.JTI = ""
	token, err := signer.SignGrant(grant)
	if err != nil {
		t.Fatalf("签发授权失败: %v", err)
	}
	payload := decodeStorageTokenPayload(t, token)
	for _, field := range []string{"method", "path", "jti"} {
		if _, ok := payload[field]; !ok {
			t.Fatalf("授权 payload 必须包含 %s 字段", field)
		}
	}
}

func TestExamPaperStorageSignerGrantAndReceiptSecretsAreIsolated(t *testing.T) {
	grantSigner, err := NewExamPaperStorageSigner("grant-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建授权签名器失败: %v", err)
	}
	receiptSigner, err := NewExamPaperStorageSigner("receipt-secret", fixedStorageSignerNow)
	if err != nil {
		t.Fatalf("创建回执签名器失败: %v", err)
	}
	receiptToken, err := receiptSigner.SignReceipt(testStorageReceipt())
	if err != nil {
		t.Fatalf("签发回执失败: %v", err)
	}
	if _, err := grantSigner.VerifyReceipt(receiptToken); !errors.Is(err, ErrStorageSignatureInvalid) {
		t.Fatalf("跨密钥验证错误不正确: %v", err)
	}
}
