package config

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config 应用配置
type Config struct {
	JWTSecret                     string // JWT密钥
	DSN                           string // 数据库连接字符串
	UploadDir                     string // 文件上传目录
	CompetitionAwardEvidenceDir   string // 竞赛证明材料私有目录
	ExamPaperDir                  string // 试卷私有文件目录
	ExamPaperStorageMode          string // 试卷文件存储模式
	ExamPaperStorageBaseURL       string // 试卷文件服务地址
	ExamPaperStorageSigningSecret string // 试卷文件签名密钥
	ExamPaperStorageReceiptSecret string // 试卷上传回执密钥
	MaxFileSize                   int64  // 最大文件大小(字节)
	EduServiceURL                 string // Python教务服务地址
	SMTPHost                      string // SMTP 地址
	SMTPPort                      string // SMTP 端口
	SMTPUser                      string // SMTP 用户名
	SMTPPass                      string // SMTP 密码/授权码
	SMTPFrom                      string // 发件人邮箱
	JPushAppKey                   string // 极光推送 AppKey
	JPushMasterSecret             string // 极光推送 MasterSecret
	SuperAdminID                  string // 超级管理员账号
	SuperAdminPass                string // 超级管理员密码

	AIEnabled                              bool     // AI 总开关
	AIInternalTestOnly                     bool     // 仅允许内测白名单访问
	AITestUserIDs                          []string // AI 内测用户 ID 白名单
	AIProvider                             string   // AI Provider 名称
	DeepSeekAPIKey                         string   // 仅从服务端环境变量读取的 DeepSeek 密钥
	DeepSeekBaseURL                        string   // DeepSeek API 地址
	DeepSeekChatModel                      string   // DeepSeek 对话模型
	AIRequestTimeoutSeconds                int      // 单次运行硬超时
	AIMaxToolSteps                         int      // 单次运行最大工具步数
	AIMaxMessageChars                      int      // 用户消息最大 grapheme 数
	AIHourlyMessageLimit                   int      // 每账号滚动一小时正式请求数
	AIUserBudgetLimitMicroYuan             int64    // 新用户默认累计预算
	AIReserveMicroYuan                     int64    // 每次模型调用的最坏成本预留
	AIInputPriceMicroYuanPerMillionTokens  int64
	AIOutputPriceMicroYuanPerMillionTokens int64
	AIPolicyRAGEnabled                     bool   // 政策知识库能力独立开关
	AILangChainRAGEnabled                  bool   // 政策请求改由 Python LCEL 完整编排
	RAGServiceURL                          string // 独立 Embedding/分词服务地址
	RAGServiceToken                        string // 内部服务鉴权令牌
	RAGEmbeddingModelVersion               string // 当前写入和查询使用的模型版本

	EduServiceToken        string // Python 教务服务共享密钥
	JWCSyncEnabled         bool   // 校园资讯同步开关
	JWCSyncIntervalMinutes int    // 校园资讯同步间隔(分钟)

	// 应用内更新相关配置
	AppReleaseDir               string // APK 发布根目录
	AppReleaseMaxSize           int64  // 单个 APK 最大字节数
	AppUpdateEnforcementEnabled bool   // 是否启用 426 最低版本拦截（阶段 D 使用）
	AllowMissingVersionHeaders  bool   // 缺失 X-App-Version-* 头时是否放行（阶段 D 使用）
	AppReleaseUseAccelRedirect  bool   // 是否使用 Nginx X-Accel-Redirect 投递大文件
	AppReleaseAccelPrefix       string // X-Accel-Redirect 路径前缀
	LegalConsentEnforcement     string // 法律协议门禁模式：off、soft、hard
}

const (
	ExamPaperStorageModeLocal          = "local"
	ExamPaperStorageModeRemote         = "remote"
	ExamPaperStorageModeReadonlyRemote = "readonly-remote"
)

// Load 从环境变量加载配置
func Load() *Config {
	content, err := os.ReadFile(".env")
	if err != nil {
		content, err = os.ReadFile("/opt/shenliyuan/.env")
	}
	if err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				key := strings.TrimSpace(parts[0])
				// systemd、容器与测试显式注入的进程环境优先于文件默认值，
				// 避免源码目录遗留 .env 覆盖部署参数或 t.Setenv。
				if _, exists := os.LookupEnv(key); !exists {
					os.Setenv(key, strings.TrimSpace(parts[1]))
				}
			}
		}
	}

	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		panic(fmt.Errorf("必须设置 JWT_SECRET 环境变量"))
	}

	dsn := os.Getenv("DSN")
	if dsn == "" || dsn == "./shenliyuan.db" || dsn == "shenliyuan.db" {
		dsn = "/opt/shenliyuan/shenliyuan.db"
		// 兼容本地开发环境
		if _, err := os.Stat(dsn); os.IsNotExist(err) {
			dsn = "./shenliyuan.db"
		}
	}

	uploadDir := os.Getenv("UPLOAD_DIR")
	if uploadDir == "" {
		uploadDir = "./uploads"
	}

	examPaperDir := os.Getenv("EXAM_PAPER_DIR")
	if examPaperDir == "" {
		examPaperDir = "./private/exam-papers"
		if os.Getenv("GIN_MODE") == "release" {
			examPaperDir = "/opt/shenliyuan/private/exam-papers"
		}
	}
	competitionAwardEvidenceDir := os.Getenv("COMPETITION_AWARD_EVIDENCE_DIR")
	if competitionAwardEvidenceDir == "" {
		competitionAwardEvidenceDir = "./private/competition-award-evidence"
		if os.Getenv("GIN_MODE") == "release" {
			competitionAwardEvidenceDir = "/opt/shenliyuan/private/competition-award-evidence"
		}
	}

	releaseMode := os.Getenv("GIN_MODE") == "release"

	examPaperStorageMode := strings.TrimSpace(os.Getenv("EXAM_PAPER_STORAGE_MODE"))
	if examPaperStorageMode == "" {
		examPaperStorageMode = ExamPaperStorageModeLocal
	}
	examPaperStorageBaseURL := strings.TrimSpace(os.Getenv("EXAM_PAPER_STORAGE_BASE_URL"))
	examPaperStorageSigningSecret := strings.TrimSpace(os.Getenv("EXAM_PAPER_STORAGE_SIGNING_SECRET"))
	examPaperStorageReceiptSecret := strings.TrimSpace(os.Getenv("EXAM_PAPER_STORAGE_RECEIPT_SECRET"))
	if err := validateExamPaperStorageConfig(examPaperStorageMode, examPaperStorageBaseURL, examPaperStorageSigningSecret, examPaperStorageReceiptSecret, releaseMode); err != nil {
		panic(err)
	}

	eduServiceURL := os.Getenv("EDU_SERVICE_URL")
	if eduServiceURL == "" {
		eduServiceURL = "http://python-edu-service:8000"
	}

	smtpHost := os.Getenv("SMTP_HOST")
	smtpPort := os.Getenv("SMTP_PORT")
	if smtpPort == "" {
		smtpPort = "587"
	}
	smtpUser := os.Getenv("SMTP_USER")
	smtpPass := os.Getenv("SMTP_PASS")
	smtpFrom := os.Getenv("SMTP_FROM")
	if smtpFrom == "" {
		smtpFrom = smtpUser
	}

	jpushAppKey := os.Getenv("JPUSH_APP_KEY")
	jpushMasterSecret := os.Getenv("JPUSH_MASTER_SECRET")

	superAdminID := os.Getenv("SUPER_ADMIN_ID")
	if superAdminID == "" {
		panic(fmt.Errorf("必须设置 SUPER_ADMIN_ID 环境变量"))
	}

	superAdminPass := os.Getenv("SUPER_ADMIN_PASSWORD")
	if superAdminPass == "" {
		panic(fmt.Errorf("必须设置 SUPER_ADMIN_PASSWORD 环境变量"))
	}

	if releaseMode {
		if isPlaceholderSecret(jwtSecret, []string{
			"dev-only-secret-do-not-use-in-production",
			"your-super-secret-jwt-key-change-this",
			"change_me_in_env",
		}) {
			panic(fmt.Errorf("生产环境必须设置安全的 JWT_SECRET 环境变量"))
		}
		if isPlaceholderSecret(superAdminPass, []string{
			"super_admin_password_change_this",
			"change_me_in_env",
			"admin123",
			"admin",
			"password",
		}) {
			panic(fmt.Errorf("生产环境必须设置安全的 SUPER_ADMIN_PASSWORD 环境变量"))
		}
		if err := ensurePrivateDirsOutsidePublicUploads(uploadDir, examPaperDir, competitionAwardEvidenceDir); err != nil {
			panic(err)
		}
	}

	eduServiceToken := os.Getenv("EDU_SERVICE_TOKEN")

	// 校园资讯同步开关
	jwcSyncEnabled := false
	if v := os.Getenv("JWC_SYNC_ENABLED"); strings.ToLower(v) == "true" {
		jwcSyncEnabled = true
	}

	// 校园资讯同步间隔
	jwcSyncIntervalMinutes := 20
	if v := os.Getenv("JWC_SYNC_INTERVAL_MINUTES"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			if n < 5 {
				n = 5
			} else if n > 1440 {
				n = 1440
			}
			jwcSyncIntervalMinutes = n
		}
	}

	// 生产环境中 Python 教务服务只接受服务间调用，令牌不能为空。
	if os.Getenv("GIN_MODE") == "release" {
		if eduServiceToken == "" {
			panic(fmt.Errorf("生产环境必须设置 EDU_SERVICE_TOKEN 环境变量"))
		}
	}

	// 应用内更新相关配置
	appReleaseDir := os.Getenv("APP_RELEASE_DIR")
	if appReleaseDir == "" {
		appReleaseDir = "/opt/shenliyuan/releases"
		if os.Getenv("GIN_MODE") != "release" {
			appReleaseDir = "./releases"
		}
	}
	appReleaseMaxSizeMB := 200
	if v := os.Getenv("APP_RELEASE_MAX_SIZE_MB"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			appReleaseMaxSizeMB = n
		}
	}
	appUpdateEnforcementEnabled := strings.EqualFold(strings.TrimSpace(os.Getenv("APP_UPDATE_ENFORCEMENT_ENABLED")), "true")
	allowMissingVersionHeaders := true
	if v := strings.TrimSpace(os.Getenv("APP_UPDATE_ALLOW_MISSING_VERSION_HEADERS")); v != "" {
		allowMissingVersionHeaders = strings.EqualFold(v, "true")
	}
	appReleaseUseAccelRedirect := strings.EqualFold(strings.TrimSpace(os.Getenv("APP_RELEASE_USE_ACCEL_REDIRECT")), "true")
	appReleaseAccelPrefix := strings.TrimSpace(os.Getenv("APP_RELEASE_ACCEL_PREFIX"))
	if appReleaseAccelPrefix == "" {
		appReleaseAccelPrefix = "/_internal/app-releases/"
	}
	legalConsentEnforcement := strings.ToLower(strings.TrimSpace(os.Getenv("LEGAL_CONSENT_ENFORCEMENT")))
	if legalConsentEnforcement == "" {
		legalConsentEnforcement = "soft"
	}
	if legalConsentEnforcement != "off" && legalConsentEnforcement != "soft" && legalConsentEnforcement != "hard" {
		panic(fmt.Errorf("LEGAL_CONSENT_ENFORCEMENT 只能是 off、soft 或 hard"))
	}

	aiEnabled := envBool("AI_ENABLED", false)
	aiInternalTestOnly := envBool("AI_INTERNAL_TEST_ONLY", true)
	aiTestUserIDs := splitNonEmpty(os.Getenv("AI_TEST_USER_IDS"))
	aiProvider := strings.ToLower(strings.TrimSpace(os.Getenv("AI_PROVIDER")))
	if aiProvider == "" {
		aiProvider = "deepseek"
	}
	deepSeekAPIKey := strings.TrimSpace(os.Getenv("DEEPSEEK_API_KEY"))
	deepSeekBaseURL := strings.TrimRight(strings.TrimSpace(os.Getenv("DEEPSEEK_BASE_URL")), "/")
	if deepSeekBaseURL == "" {
		deepSeekBaseURL = "https://api.deepseek.com"
	}
	deepSeekChatModel := strings.TrimSpace(os.Getenv("DEEPSEEK_CHAT_MODEL"))
	if deepSeekChatModel == "" {
		deepSeekChatModel = "deepseek-v4-flash"
	}
	aiRequestTimeoutSeconds := envIntInRange("AI_REQUEST_TIMEOUT_SECONDS", 60, 5, 120)
	aiMaxToolSteps := envIntInRange("AI_MAX_TOOL_STEPS", 3, 1, 5)
	aiMaxMessageChars := envIntInRange("AI_MAX_MESSAGE_CHARS", 120, 50, 300)
	aiHourlyMessageLimit := envIntInRange("AI_HOURLY_MESSAGE_LIMIT", 3, 1, 100)
	aiUserBudgetLimitMicroYuan := envInt64InRange("AI_USER_BUDGET_LIMIT_MICRO_YUAN", 10_000_000, 1, 1_000_000_000)
	aiReserveMicroYuan := envInt64InRange("AI_RESERVE_MICRO_YUAN", 20_000, 1, aiUserBudgetLimitMicroYuan)
	aiInputPrice := envInt64InRange("AI_INPUT_PRICE_MICRO_YUAN_PER_MILLION_TOKENS", 4_000_000, 0, 1_000_000_000)
	aiOutputPrice := envInt64InRange("AI_OUTPUT_PRICE_MICRO_YUAN_PER_MILLION_TOKENS", 16_000_000, 0, 1_000_000_000)
	aiPolicyRAGEnabled := envBool("AI_POLICY_RAG_ENABLED", false)
	aiLangChainRAGEnabled := envBool("AI_LANGCHAIN_RAG_ENABLED", false)
	ragServiceURL := strings.TrimRight(strings.TrimSpace(os.Getenv("RAG_SERVICE_URL")), "/")
	if ragServiceURL == "" {
		ragServiceURL = "http://127.0.0.1:18001"
	}
	ragServiceToken := strings.TrimSpace(os.Getenv("RAG_SERVICE_TOKEN"))
	ragEmbeddingModelVersion := strings.TrimSpace(os.Getenv("RAG_EMBEDDING_MODEL_VERSION"))
	if ragEmbeddingModelVersion == "" {
		ragEmbeddingModelVersion = "paraphrase-multilingual-minilm-l12-v2-384-v1"
	}
	if err := validateAIConfig(aiEnabled, aiInternalTestOnly, aiTestUserIDs, aiProvider, deepSeekAPIKey, deepSeekBaseURL, deepSeekChatModel, aiPolicyRAGEnabled, aiLangChainRAGEnabled, ragServiceURL, ragServiceToken); err != nil {
		panic(err)
	}

	return &Config{
		JWTSecret:                     jwtSecret,
		DSN:                           dsn,
		UploadDir:                     uploadDir,
		CompetitionAwardEvidenceDir:   competitionAwardEvidenceDir,
		ExamPaperDir:                  examPaperDir,
		ExamPaperStorageMode:          examPaperStorageMode,
		ExamPaperStorageBaseURL:       examPaperStorageBaseURL,
		ExamPaperStorageSigningSecret: examPaperStorageSigningSecret,
		ExamPaperStorageReceiptSecret: examPaperStorageReceiptSecret,
		MaxFileSize:                   10 * 1024 * 1024, // 10MB
		EduServiceURL:                 eduServiceURL,
		SMTPHost:                      smtpHost,
		SMTPPort:                      smtpPort,
		SMTPUser:                      smtpUser,
		SMTPPass:                      smtpPass,
		SMTPFrom:                      smtpFrom,
		JPushAppKey:                   jpushAppKey,
		JPushMasterSecret:             jpushMasterSecret,
		SuperAdminID:                  superAdminID,
		SuperAdminPass:                superAdminPass,

		AIEnabled:                              aiEnabled,
		AIInternalTestOnly:                     aiInternalTestOnly,
		AITestUserIDs:                          aiTestUserIDs,
		AIProvider:                             aiProvider,
		DeepSeekAPIKey:                         deepSeekAPIKey,
		DeepSeekBaseURL:                        deepSeekBaseURL,
		DeepSeekChatModel:                      deepSeekChatModel,
		AIRequestTimeoutSeconds:                aiRequestTimeoutSeconds,
		AIMaxToolSteps:                         aiMaxToolSteps,
		AIMaxMessageChars:                      aiMaxMessageChars,
		AIHourlyMessageLimit:                   aiHourlyMessageLimit,
		AIUserBudgetLimitMicroYuan:             aiUserBudgetLimitMicroYuan,
		AIReserveMicroYuan:                     aiReserveMicroYuan,
		AIInputPriceMicroYuanPerMillionTokens:  aiInputPrice,
		AIOutputPriceMicroYuanPerMillionTokens: aiOutputPrice,
		AIPolicyRAGEnabled:                     aiPolicyRAGEnabled,
		AILangChainRAGEnabled:                  aiLangChainRAGEnabled,
		RAGServiceURL:                          ragServiceURL,
		RAGServiceToken:                        ragServiceToken,
		RAGEmbeddingModelVersion:               ragEmbeddingModelVersion,

		EduServiceToken:        eduServiceToken,
		JWCSyncEnabled:         jwcSyncEnabled,
		JWCSyncIntervalMinutes: jwcSyncIntervalMinutes,

		AppReleaseDir:               appReleaseDir,
		AppReleaseMaxSize:           int64(appReleaseMaxSizeMB) * 1024 * 1024,
		AppUpdateEnforcementEnabled: appUpdateEnforcementEnabled,
		AllowMissingVersionHeaders:  allowMissingVersionHeaders,
		AppReleaseUseAccelRedirect:  appReleaseUseAccelRedirect,
		AppReleaseAccelPrefix:       appReleaseAccelPrefix,
		LegalConsentEnforcement:     legalConsentEnforcement,
	}
}

func envBool(name string, fallback bool) bool {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		panic(fmt.Errorf("%s 必须为 true 或 false", name))
	}
	return parsed
}

func envIntInRange(name string, fallback, minimum, maximum int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < minimum || parsed > maximum {
		panic(fmt.Errorf("%s 必须在 %d 到 %d 之间", name, minimum, maximum))
	}
	return parsed
}

func envInt64InRange(name string, fallback, minimum, maximum int64) int64 {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil || parsed < minimum || parsed > maximum {
		panic(fmt.Errorf("%s 必须在 %d 到 %d 之间", name, minimum, maximum))
	}
	return parsed
}

func splitNonEmpty(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	seen := make(map[string]struct{}, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if _, exists := seen[part]; exists {
			continue
		}
		seen[part] = struct{}{}
		result = append(result, part)
	}
	return result
}

func validateAIConfig(enabled, internalOnly bool, whitelist []string, provider, apiKey, baseURL, model string, policyRAGEnabled, langChainRAGEnabled bool, ragServiceURL, ragServiceToken string) error {
	if provider != "deepseek" && provider != "mock" {
		return fmt.Errorf("AI_PROVIDER 只能是 deepseek 或 mock")
	}
	if !enabled {
		return nil
	}
	if internalOnly && len(whitelist) == 0 {
		return fmt.Errorf("AI_INTERNAL_TEST_ONLY=true 时必须设置 AI_TEST_USER_IDS")
	}
	if provider == "deepseek" && apiKey == "" && !langChainRAGEnabled {
		return fmt.Errorf("AI_ENABLED=true 且 AI_PROVIDER=deepseek 时必须设置 DEEPSEEK_API_KEY")
	}
	if strings.TrimSpace(model) == "" {
		return fmt.Errorf("AI_ENABLED=true 时模型名称不能为空")
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("DEEPSEEK_BASE_URL 必须是无用户信息的 HTTPS 地址")
	}
	if policyRAGEnabled {
		ragURL, err := url.Parse(ragServiceURL)
		if err != nil || (ragURL.Scheme != "http" && ragURL.Scheme != "https") || ragURL.Host == "" || ragURL.User != nil {
			return fmt.Errorf("RAG_SERVICE_URL 必须是无用户信息的 HTTP(S) 地址")
		}
		if ragServiceToken == "" {
			return fmt.Errorf("AI_POLICY_RAG_ENABLED=true 时必须设置 RAG_SERVICE_TOKEN")
		}
	}
	if langChainRAGEnabled && !policyRAGEnabled {
		return fmt.Errorf("AI_LANGCHAIN_RAG_ENABLED=true 时必须同时启用 AI_POLICY_RAG_ENABLED")
	}
	return nil
}

func validateExamPaperStorageConfig(mode, baseURL, signingSecret, receiptSecret string, releaseMode bool) error {
	switch mode {
	case ExamPaperStorageModeLocal:
		return nil
	case ExamPaperStorageModeRemote, ExamPaperStorageModeReadonlyRemote:
		if !releaseMode {
			return nil
		}
		if baseURL == "" || signingSecret == "" || receiptSecret == "" {
			return fmt.Errorf("生产环境远端试卷存储必须完整设置 EXAM_PAPER_STORAGE_BASE_URL、EXAM_PAPER_STORAGE_SIGNING_SECRET 和 EXAM_PAPER_STORAGE_RECEIPT_SECRET")
		}
		if strings.TrimSpace(signingSecret) == strings.TrimSpace(receiptSecret) {
			return fmt.Errorf("EXAM_PAPER_STORAGE_SIGNING_SECRET 与 EXAM_PAPER_STORAGE_RECEIPT_SECRET 不能相同")
		}
		parsed, err := url.Parse(baseURL)
		if err != nil ||
			!strings.EqualFold(parsed.Scheme, "https") ||
			parsed.Hostname() != "139.196.148.174" ||
			(parsed.Port() != "" && parsed.Port() != "443") ||
			parsed.User != nil ||
			(parsed.Path != "" && parsed.Path != "/") ||
			parsed.RawQuery != "" ||
			parsed.Fragment != "" {
			return fmt.Errorf("生产环境 EXAM_PAPER_STORAGE_BASE_URL 必须是 https://139.196.148.174")
		}
		return nil
	default:
		return fmt.Errorf("EXAM_PAPER_STORAGE_MODE 无效: %q", mode)
	}
}

func isPlaceholderSecret(value string, placeholders []string) bool {
	normalized := strings.TrimSpace(value)
	for _, placeholder := range placeholders {
		if normalized == placeholder {
			return true
		}
	}
	return false
}

func ensurePrivateDirsOutsidePublicUploads(uploadDir string, privateDirs ...string) error {
	uploadAbs, err := filepath.Abs(filepath.Clean(uploadDir))
	if err != nil {
		return fmt.Errorf("解析 UPLOAD_DIR 失败: %w", err)
	}
	for _, privateDir := range privateDirs {
		privateAbs, err := filepath.Abs(filepath.Clean(privateDir))
		if err != nil {
			return fmt.Errorf("解析私有目录失败: %w", err)
		}
		relative, err := filepath.Rel(uploadAbs, privateAbs)
		if err != nil {
			return fmt.Errorf("校验私有目录失败: %w", err)
		}
		if relative == "." || (!strings.HasPrefix(relative, "..") && !filepath.IsAbs(relative)) {
			return fmt.Errorf("私有目录不能等于或位于公开 UPLOAD_DIR 内: %s", privateDir)
		}
	}
	return nil
}
