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

func TestLoadCompetitionAwardEvidenceDirDefaultsByEnvironmentAndAllowsOverride(t *testing.T) {
	setBaseConfigEnv(t, "release")
	t.Setenv("COMPETITION_AWARD_EVIDENCE_DIR", "")
	production := Load()
	require.Equal(t, "/opt/shenliyuan/private/competition-award-evidence", production.CompetitionAwardEvidenceDir)

	t.Setenv("COMPETITION_AWARD_EVIDENCE_DIR", "/srv/private/competition-evidence")
	overridden := Load()
	require.Equal(t, "/srv/private/competition-evidence", overridden.CompetitionAwardEvidenceDir)
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

func TestLoadReleaseRejectsCompetitionEvidenceDirInsidePublicUploads(t *testing.T) {
	setBaseConfigEnv(t, "release")
	t.Setenv("COMPETITION_AWARD_EVIDENCE_DIR", "/opt/shenliyuan/uploads/competition-evidence")

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
			baseURL:       "https://139.196.148.174",
			receiptSecret: "receipt-secret",
		},
		{
			name:          "缺少回执密钥",
			mode:          "readonly-remote",
			baseURL:       "https://139.196.148.174",
			signingSecret: "signing-secret",
		},
		{
			name:          "远端地址不是固定文件服务器IP",
			mode:          "remote",
			baseURL:       "https://paper.example.com",
			signingSecret: "signing-secret",
			receiptSecret: "receipt-secret",
		},
		{
			name:          "远端地址不是HTTPS",
			mode:          "remote",
			baseURL:       "http://paper.example.com",
			signingSecret: "signing-secret",
			receiptSecret: "receipt-secret",
		},
		{
			name:          "远端地址缺少主机名",
			mode:          "remote",
			baseURL:       "https://@",
			signingSecret: "signing-secret",
			receiptSecret: "receipt-secret",
		},
		{
			name:          "远端地址包含用户信息",
			mode:          "remote",
			baseURL:       "https://user:password@paper.example.com",
			signingSecret: "signing-secret",
			receiptSecret: "receipt-secret",
		},
		{
			name:          "远端地址包含fragment",
			mode:          "readonly-remote",
			baseURL:       "https://paper.example.com/download#private",
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

func TestLoadReleaseRejectsSharedExamPaperStorageSecret(t *testing.T) {
	setBaseConfigEnv(t, "release")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "remote")
	t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", "https://139.196.148.174")
	t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", "  shared-storage-secret  ")
	t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", "shared-storage-secret")

	require.PanicsWithError(
		t,
		"EXAM_PAPER_STORAGE_SIGNING_SECRET 与 EXAM_PAPER_STORAGE_RECEIPT_SECRET 不能相同",
		func() { Load() },
	)
}

func TestLoadReleaseAcceptsDistinctExamPaperStorageSecrets(t *testing.T) {
	setBaseConfigEnv(t, "release")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "remote")
	t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", "https://139.196.148.174")
	t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", "signing-secret-0123456789abcdef")
	t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", "receipt-secret-fedcba9876543210")

	cfg := Load()
	require.Equal(t, "signing-secret-0123456789abcdef", cfg.ExamPaperStorageSigningSecret)
	require.Equal(t, "receipt-secret-fedcba9876543210", cfg.ExamPaperStorageReceiptSecret)
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
	t.Setenv("COMPETITION_AWARD_EVIDENCE_DIR", "/opt/shenliyuan/private/competition-award-evidence")
	t.Setenv("EXAM_PAPER_STORAGE_MODE", "")
	t.Setenv("EXAM_PAPER_STORAGE_BASE_URL", "")
	t.Setenv("EXAM_PAPER_STORAGE_SIGNING_SECRET", "")
	t.Setenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET", "")
	t.Setenv("AI_ENABLED", "false")
	t.Setenv("AI_INTERNAL_TEST_ONLY", "true")
	t.Setenv("AI_TEST_USER_IDS", "")
	t.Setenv("AI_PROVIDER", "deepseek")
	t.Setenv("DEEPSEEK_API_KEY", "")
	t.Setenv("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
	t.Setenv("AI_POLICY_RAG_ENABLED", "false")
	t.Setenv("AI_LANGCHAIN_RAG_ENABLED", "false")
	t.Setenv("RAG_SERVICE_TOKEN", "")
}

func TestLoadAIConfigDefaultsDisabled(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	cfg := Load()
	require.False(t, cfg.AIEnabled)
	require.True(t, cfg.AIInternalTestOnly)
	require.Empty(t, cfg.DeepSeekAPIKey)
	require.Equal(t, "deepseek-v4-flash", cfg.DeepSeekChatModel)
	require.False(t, cfg.AILangChainRAGEnabled)
}

func TestLoadLangChainRAGDoesNotRequireGoProviderKey(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("AI_ENABLED", "true")
	t.Setenv("AI_TEST_USER_IDS", "18")
	t.Setenv("AI_POLICY_RAG_ENABLED", "true")
	t.Setenv("AI_LANGCHAIN_RAG_ENABLED", "true")
	t.Setenv("RAG_SERVICE_URL", "http://127.0.0.1:18001")
	t.Setenv("RAG_SERVICE_TOKEN", "internal-rag-token")
	cfg := Load()
	require.True(t, cfg.AILangChainRAGEnabled)
	require.Empty(t, cfg.DeepSeekAPIKey)
}

func TestLoadLangChainRAGRequiresPolicyCapability(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("AI_ENABLED", "true")
	t.Setenv("AI_TEST_USER_IDS", "18")
	t.Setenv("AI_LANGCHAIN_RAG_ENABLED", "true")
	require.Panics(t, func() { Load() })
}

func TestLoadAIConfigRequiresServerKeyAndWhitelist(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("AI_ENABLED", "true")
	require.Panics(t, func() { Load() })

	t.Setenv("AI_TEST_USER_IDS", "18, 19")
	require.Panics(t, func() { Load() })

	t.Setenv("DEEPSEEK_API_KEY", "server-only-key")
	cfg := Load()
	require.Equal(t, []string{"18", "19"}, cfg.AITestUserIDs)
	require.Equal(t, "server-only-key", cfg.DeepSeekAPIKey)
}

func TestLoadPolicyRAGRequiresInternalServiceToken(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("AI_ENABLED", "true")
	t.Setenv("AI_TEST_USER_IDS", "18")
	t.Setenv("DEEPSEEK_API_KEY", "server-only-key")
	t.Setenv("AI_POLICY_RAG_ENABLED", "true")
	t.Setenv("RAG_SERVICE_URL", "http://127.0.0.1:18001")
	t.Setenv("RAG_SERVICE_TOKEN", "")
	require.Panics(t, func() { Load() })
	t.Setenv("RAG_SERVICE_TOKEN", "internal-rag-token")
	cfg := Load()
	require.True(t, cfg.AIPolicyRAGEnabled)
	require.Equal(t, "internal-rag-token", cfg.RAGServiceToken)
}

func TestLoadAIRejectsUnsafeLimits(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("AI_MAX_MESSAGE_CHARS", "49")
	require.Panics(t, func() { Load() })
	t.Setenv("AI_MAX_MESSAGE_CHARS", "301")
	require.Panics(t, func() { Load() })
}

func TestLoadAIMessageLimitDefaultsTo120AndAllowsConfiguredRange(t *testing.T) {
	setBaseConfigEnv(t, "debug")
	t.Setenv("AI_MAX_MESSAGE_CHARS", "")
	require.Equal(t, 120, Load().AIMaxMessageChars)

	t.Setenv("AI_MAX_MESSAGE_CHARS", "50")
	require.Equal(t, 50, Load().AIMaxMessageChars)
	t.Setenv("AI_MAX_MESSAGE_CHARS", "300")
	require.Equal(t, 300, Load().AIMaxMessageChars)
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
