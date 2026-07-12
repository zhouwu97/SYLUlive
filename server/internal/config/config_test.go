package config

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestLoadExamPaperDirDefaultsByEnvironmentAndAllowsOverride(t *testing.T) {
	t.Setenv("JWT_SECRET", "test-secret")
	t.Setenv("SUPER_ADMIN_ID", "root-admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "test-password")
	t.Setenv("EDU_SERVICE_TOKEN", "test-service-token")
	t.Setenv("GIN_MODE", "release")
	t.Setenv("EXAM_PAPER_DIR", "")
	production := Load()
	if production.ExamPaperDir != "/opt/shenliyuan/private/exam-papers" {
		t.Fatalf("生产默认私有目录错误: %q", production.ExamPaperDir)
	}

	t.Setenv("EXAM_PAPER_DIR", "/srv/private/papers")
	overridden := Load()
	if overridden.ExamPaperDir != "/srv/private/papers" {
		t.Fatalf("EXAM_PAPER_DIR 覆盖失败: %q", overridden.ExamPaperDir)
	}
}

func TestLoadReleaseRejectsPlaceholderSecrets(t *testing.T) {
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "your-super-secret-jwt-key-change-this")
	t.Setenv("SUPER_ADMIN_ID", "admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "change_me_in_env")

	assertLoadPanics(t)
}

func TestLoadReleaseRejectsExamPaperDirInsidePublicUploads(t *testing.T) {
	t.Setenv("GIN_MODE", "release")
	t.Setenv("JWT_SECRET", "realistic-release-secret")
	t.Setenv("SUPER_ADMIN_ID", "admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "realistic-admin-password")
	t.Setenv("UPLOAD_DIR", "/opt/shenliyuan/uploads")
	t.Setenv("EXAM_PAPER_DIR", "/opt/shenliyuan/uploads/exam-papers")

	assertLoadPanics(t)
}

func TestLoadReadsRemoteExamPaperStorageConfig(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "remote")
	t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", "https://paper.example.com")
	t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", "signing-secret")
	t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", "receipt-secret")

	cfg := Load()
	require.Equal(t, "remote", cfg.ExamPaperStorageMode)
	require.Equal(t, "https://paper.example.com", cfg.ExamPaperStorageBaseURL)
	require.Equal(t, "signing-secret", cfg.ExamPaperStorageSigningSecret)
	require.Equal(t, "receipt-secret", cfg.ExamPaperStorageReceiptSecret)
}

func TestLoadReadsReadonlyRemoteExamPaperStorageConfig(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "readonly-remote")
	t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", "https://paper.example.com")
	t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", "signing-secret")
	t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", "receipt-secret")

	cfg := Load()
	require.Equal(t, "readonly-remote", cfg.ExamPaperStorageMode)
}

func TestLoadRejectsInvalidExamPaperStorageMode(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "hybrid")

	require.Panics(t, func() { Load() })
}

func TestLoadReleaseRejectsIncompleteOrInsecureRemoteStorageConfig(t *testing.T) {
	tests := []struct {
		name          string
		mode          string
		baseURL       string
		signingSecret string
		receiptSecret string
	}{
		{
			name:          "缺少签名密钥",
			mode:          "remote",
			baseURL:       "https://paper.example.com",
			receiptSecret: "receipt-secret",
		},
		{
			name:          "缺少回执密钥",
			mode:          "readonly-remote",
			baseURL:       "https://paper.example.com",
			signingSecret: "signing-secret",
		},
		{
			name:          "远端地址不是HTTPS",
			mode:          "remote",
			baseURL:       "http://paper.example.com",
			signingSecret: "signing-secret",
			receiptSecret: "receipt-secret",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setBaseConfigEnv(t, "release")
			t.Setenv("EXAM_PAPER_STORAGE_MODE", tt.mode)
			t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", tt.baseURL)
			t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", tt.signingSecret)
			t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", tt.receiptSecret)

			require.Panics(t, func() { Load() })
		})
	}
}

func setBaseConfigEnv(t *testing.T, ginMode string) {
	t.Helper()
	t.Setenv("GIN_MODE", ginMode)
	t.Setenv("JWT_SECRET", "realistic-release-secret")
	t.Setenv("SUPER_ADMIN_ID", "admin")
	t.Setenv("SUPER_ADMIN_PASSWORD", "realistic-admin-password")
	t.Setenv("EDU_SERVICE_TOKEN", "test-service-token")
	t.Setenv("UPLOAD_DIR", "/opt/shenliyuan/uploads")
	t.Setenv("EXAM_PAPER_DIR", "/opt/shenliyuan/private/exam-papers")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "")
	t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", "")
	t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", "")
	t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", "")
}

func assertLoadPanics(t *testing.T) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatal("Load() 应该拒绝不安全的生产配置")
		}
	}()
	_ = Load()
}
