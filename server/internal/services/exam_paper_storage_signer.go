package services

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const (
	ExamPaperStoragePurposeUpload      = "upload"
	ExamPaperStoragePurposePreview     = "preview"
	ExamPaperStoragePurposeDownload    = "download"
	ExamPaperStoragePurposeClaim       = "claim"
	ExamPaperStoragePurposeDelete      = "delete"
	ExamPaperStoragePurposeMetadata    = "metadata"
	ExamPaperStoragePurposeMaintenance = "maintenance"
)

var (
	ErrStorageSignatureInvalid = errors.New("storage signature invalid")
	ErrStorageGrantExpired     = errors.New("storage grant expired")
	ErrStorageSecretRequired   = errors.New("storage signing secret required")
	ErrStorageReceiptInvalid   = errors.New("storage receipt invalid")
)

// ExamPaperStorageGrant 表示主服务发给文件服务的短时授权。
type ExamPaperStorageGrant struct {
	Purpose   string `json:"purpose"`
	SessionID string `json:"session_id,omitempty"`
	FileKey   string `json:"file_key,omitempty"`
	UserID    uint   `json:"user_id,omitempty"`
	PaperID   uint   `json:"paper_id,omitempty"`
	Method    string `json:"method"`
	Path      string `json:"path"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
	JTI       string `json:"jti"`
}

// ExamPaperUploadReceipt 表示文件服务确认接收文件后的不可伪造回执。
type ExamPaperUploadReceipt struct {
	SessionID string `json:"session_id"`
	FileKey   string `json:"file_key"`
	FileSize  int64  `json:"file_size"`
	SHA256    string `json:"sha256"`
	IssuedAt  int64  `json:"issued_at"`
}

// ExamPaperStorageSigner 使用 HMAC-SHA256 签发和验证存储授权。
type ExamPaperStorageSigner struct {
	secret []byte
	now    func() time.Time
}

// NewExamPaperStorageSigner 创建签名器。secret 为空时拒绝创建，避免生成无密钥签名。
func NewExamPaperStorageSigner(secret string, now func() time.Time) (*ExamPaperStorageSigner, error) {
	secret = strings.TrimSpace(secret)
	if secret == "" {
		return nil, ErrStorageSecretRequired
	}
	if now == nil {
		now = time.Now
	}
	return &ExamPaperStorageSigner{secret: []byte(secret), now: now}, nil
}

// SignGrant 签发一个授权 token。
func (s *ExamPaperStorageSigner) SignGrant(grant ExamPaperStorageGrant) (string, error) {
	grant.Method = strings.ToUpper(strings.TrimSpace(grant.Method))
	return s.sign(grant)
}

// VerifyGrant 验证授权签名、范围和有效期。
func (s *ExamPaperStorageSigner) VerifyGrant(token, expectedPurpose, expectedMethod, expectedPath string) (ExamPaperStorageGrant, error) {
	var grant ExamPaperStorageGrant
	if err := s.verify(token, &grant); err != nil {
		return ExamPaperStorageGrant{}, err
	}
	if grant.Purpose != expectedPurpose || grant.Method != strings.ToUpper(strings.TrimSpace(expectedMethod)) || grant.Path != expectedPath {
		return ExamPaperStorageGrant{}, ErrStorageSignatureInvalid
	}
	if grant.ExpiresAt <= s.now().Unix() {
		return ExamPaperStorageGrant{}, ErrStorageGrantExpired
	}
	return grant, nil
}

// SignReceipt 签发文件服务上传回执。
func (s *ExamPaperStorageSigner) SignReceipt(receipt ExamPaperUploadReceipt) (string, error) {
	if err := validateExamPaperUploadReceipt(receipt); err != nil {
		return "", err
	}
	return s.sign(receipt)
}

// VerifyReceipt 验证上传回执的 HMAC 签名和 JSON 格式。
func (s *ExamPaperStorageSigner) VerifyReceipt(token string) (ExamPaperUploadReceipt, error) {
	var receipt ExamPaperUploadReceipt
	if err := s.verify(token, &receipt); err != nil {
		return ExamPaperUploadReceipt{}, err
	}
	if err := validateExamPaperUploadReceipt(receipt); err != nil {
		return ExamPaperUploadReceipt{}, err
	}
	return receipt, nil
}

func validateExamPaperUploadReceipt(receipt ExamPaperUploadReceipt) error {
	if strings.TrimSpace(receipt.SessionID) == "" ||
		strings.TrimSpace(receipt.FileKey) == "" ||
		receipt.FileSize <= 0 ||
		len(receipt.SHA256) != sha256.Size*2 ||
		receipt.IssuedAt <= 0 {
		return ErrStorageReceiptInvalid
	}
	if _, err := hex.DecodeString(receipt.SHA256); err != nil {
		return ErrStorageReceiptInvalid
	}
	return nil
}

func (s *ExamPaperStorageSigner) sign(value any) (string, error) {
	if s == nil || len(s.secret) == 0 {
		return "", ErrStorageSecretRequired
	}
	payload, err := json.Marshal(value)
	if err != nil {
		return "", fmt.Errorf("marshal storage token: %w", err)
	}
	payloadPart := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, s.secret)
	_, _ = mac.Write([]byte(payloadPart))
	signaturePart := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return payloadPart + "." + signaturePart, nil
}

func (s *ExamPaperStorageSigner) verify(token string, destination any) error {
	if s == nil || len(s.secret) == 0 {
		return ErrStorageSignatureInvalid
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return ErrStorageSignatureInvalid
	}
	providedSignature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ErrStorageSignatureInvalid
	}
	mac := hmac.New(sha256.New, s.secret)
	_, _ = mac.Write([]byte(parts[0]))
	if !hmac.Equal(providedSignature, mac.Sum(nil)) {
		return ErrStorageSignatureInvalid
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || json.Unmarshal(payload, destination) != nil {
		return ErrStorageSignatureInvalid
	}
	return nil
}
