package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Config 应用配置
type Config struct {
	JWTSecret                        string // JWT密钥
	DSN                              string // 数据库连接字符串
	UploadDir                        string // 文件上传目录
	ImageVariantWorkerEnabled        bool   // 是否启动异步图片变体 worker
	HomeFeedPersonalizationShadow    bool   // FEED-5 个性化 shadow（只计算+trace，不改用户排序）
	HomeFeedPersonalizationPercent   int    // FEED-5 个性化 active rollout 百分比（0~100）
	HomeFeedV5PersonalizationShadow  bool   // FEED-V5 个性化 shadow
	HomeFeedV5PersonalizationPercent int    // FEED-V5 个性化 active rollout 百分比（0~100）
	CompetitionAwardEvidenceDir      string // 竞赛证明材料私有目录
	ExamPaperDir                     string // 试卷私有文件目录
	ExamPaperStorageMode             string // 试卷文件存储模式
	ExamPaperStorageBaseURL          string // 试卷文件服务地址
	ExamPaperStorageSigningSecret    string // 试卷文件签名密钥
	ExamPaperStorageReceiptSecret    string // 试卷上传回执密钥
	MaxFileSize                      int64  // 最大文件大小(字节)
	EduServiceURL                    string // Python教务服务地址
	SMTPHost                         string // SMTP 地址
	SMTPPort                         string // SMTP 端口
	SMTPUser                         string // SMTP 用户名
	SMTPPass                         string // SMTP 密码/授权码
	SMTPFrom                         string // 发件人邮箱
	JPushAppKey                      string // 极光推送 AppKey
	JPushMasterSecret                string // 极光推送 MasterSecret
	SuperAdminID                     string // 超级管理员账号
	SuperAdminPass                   string // 超级管理员密码

	AIEnabled                              bool     // AI 总开关
	AIProvider                             string   // AI Provider 名称
	AIAPIKey                               string   // 仅从服务端环境变量读取的模型网关密钥
	AIBaseURL                              string   // OpenAI 兼容模型网关地址
	AIChatModel                            string   // 对话模型
	AIRequestTimeoutSeconds                int      // 单次运行硬超时
	AILegacyMaxOutputTokens                int      // 旧 Go RAG 单次生成的最大输出 token
	AIMaxToolSteps                         int      // 单次运行最大工具步数
	AIMaxMessageChars                      int      // 用户消息最大 grapheme 数
	AIHourlyMessageLimit                   int      // 每账号滚动一小时正式请求数
	AIUnlimitedStudentIDs                  []string // 不受滚动小时次数限制的已验证学号
	AIQuotaExemptUserIDs                   []uint   // 不受滚动小时次数限制的内部测试用户 ID
	AIUserBudgetLimitMicroYuan             int64    // 新用户默认累计预算
	AIReserveMicroYuan                     int64    // 每次模型调用的最坏成本预留
	AIInputPriceMicroYuanPerMillionTokens  int64
	AIOutputPriceMicroYuanPerMillionTokens int64
	AIPolicyRAGEnabled                     bool     // 政策知识库能力独立开关
	AILangChainRAGEnabled                  bool     // 政策请求改由 Python LCEL 完整编排
	AILangChainRAGRolloutPercent           int      // 稳定分配给 LangChain 的账号比例
	AILegacyRAGEnabled                     bool     // 旧 Go 检索与生成路径独立回滚开关
	AIAgentEnabled                         bool     // Agent Kernel v5 总开关
	AIAgentRolloutPercent                  int      // Agent v5 用户灰度比例
	AIAgentRolloutUserIDs                  []uint   // Agent v5 显式放行用户
	AIAgentAppVersionAllowlist             []string // Agent v5 客户端版本白名单
	AIAgentCapabilityAllowlist             []string // Agent v5 能力白名单
	AIAgentModeAllowlist                   []string // Agent v5 执行模式白名单
	AIAgentShadowEnabled                   bool     // Shadow 观察开关
	AIAgentShadowPercent                   int      // Shadow 观察比例
	AIAgentActionsEnabled                  bool     // Agent Action 提案开关
	AIAgentPersonalDataEnabled             bool     // Agent 个人数据能力开关
	AIAgentDeepModeEnabled                 bool     // Agent deep 模式开关
	AIShadowTraceRetentionDays             int      // Shadow 观测事件保留天数
	AIFailureTraceRetentionDays            int      // 用户反馈/失败分类事件保留天数
	RAGServiceURL                          string   // 独立 Embedding/分词服务地址
	RAGServiceToken                        string   // 内部服务鉴权令牌
	RAGEmbeddingModelVersion               string   // 当前写入和查询使用的模型版本
	AIExternalMCPEnabled                   bool     // 是否启用独立 Hy3 MCP 包装工具
	AIExternalMCPTransport                 string   // local_stdio 或 ssh_stdio
	AIExternalMCPCommand                   string   // 本机 MCP 固定启动包装器的绝对路径
	AIExternalMCPToolTimeoutSeconds        int      // 单次 MCP 调用硬超时
	AIExternalMCPMaxCallsPerRun            int      // 每个 AI Run 允许的外部 MCP 调用数
	AIExternalMCPSshHost                   string   // 受限 MCP SSH 主机
	AIExternalMCPSshPort                   int      // 受限 MCP SSH 端口
	AIExternalMCPSshUser                   string   // 受限 MCP SSH 用户
	AIExternalMCPSshKeyPath                string   // Go 服务读取的专用 SSH 私钥绝对路径
	AIExternalMCPKnownHostsPath            string   // 专用 known_hosts 绝对路径
	AIUnifiedMCPURL                        string   // Agent Contract v5 纯能力 MCP Streamable HTTP 地址

	EduServiceToken        string // Python 教务服务共享密钥
	JWCSyncEnabled         bool   // 校园资讯同步开关
	JWCSyncIntervalMinutes int    // 校园资讯同步间隔(分钟)

	// 应用内更新相关配置
	AppReleaseDir                string   // APK 发布根目录
	AppReleaseMaxSize            int64    // 单个 APK 最大字节数
	AppUpdateEnforcementEnabled  bool     // 是否启用 426 最低版本拦截（阶段 D 使用）
	AllowMissingVersionHeaders   bool     // 缺失 X-App-Version-* 头时是否放行（阶段 D 使用）
	AppReleaseUseAccelRedirect   bool     // 是否使用 Nginx X-Accel-Redirect 投递大文件
	AppReleaseAccelPrefix        string   // X-Accel-Redirect 路径前缀
	LegalConsentEnforcement      string   // 法律协议门禁模式：off、soft、hard
	AndroidPackageName           string   // 发布 APK 预期包名
	AndroidSigningCertificate    string   // 发布 APK 签名证书 SHA-256（无冒号大写）
	AndroidAAPT2Path             string   // aapt2 可执行文件路径
	AndroidAPKSignerPath         string   // apksigner 可执行文件路径
	AppReleaseAllowedMarketHosts []string // 外部市场跳转允许的 HTTPS 域名
	AccountIdentityReadMode      string   // 账号登录读路径：legacy 或 identity
	// SchoolDeviceCapabilityCut 表示 C3 已完成，服务端不再提供个人学校设备能力。
	// SchoolAcademicRoutesRetired 表示 Release D 已完成，旧教务/个人快照路由只返回 410。
	// 学校个人能力默认关闭；SCHOOL_AUTHORITY_RETIRED 会同时作为总闸门。
	SchoolDeviceCapabilityCut   bool
	SchoolAcademicRoutesRetired bool

	CompetitionCatalogV2Enabled         bool   // 是否开放 Catalog 2.2 管理链路
	CompetitionCandidateEngineV2Enabled bool   // 是否开放统一候选接口
	CompetitionAIExplanationEnabled     bool   // 是否允许调用外部模型解释候选
	SyluliveMCPGrant                    string // 纯 MCP 调用 Go 只读事实网关的固定 Grant
	ReviewEnabled                       bool   // 是否开放前置审核与相关投稿链路（默认 false，暂时关闭）
}

// IsReviewEnabled 返回当前是否启用了前置审核链路。
func IsReviewEnabled() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("REVIEW_ENABLED")), "true")
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
	imageVariantWorkerEnabled := envBool("IMAGE_VARIANT_WORKER_ENABLED", false)

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

	// 生产环境禁止重新打开服务端学校个人能力。子开关必须显式为 true，
	// 防止空值回退或仅设置总开关时误开放历史教务路由。
	if releaseMode {
		requireReleaseTrue(
			"SCHOOL_AUTHORITY_RETIRED",
			"SCHOOL_DEVICE_CAPABILITY_CUT",
			"SCHOOL_ACADEMIC_ROUTES_RETIRED",
		)
	}

	// 图片管线两个开关直接影响生产资源链路（worker 写盘、Nginx 直传）。release 模式
	// 必须显式设置，空值视同缺失（envBool 对空串静默回退，会形成假显式配置）。
	if releaseMode {
		for _, key := range []string{"IMAGE_VARIANT_WORKER_ENABLED", "UPLOAD_USE_ACCEL_REDIRECT"} {
			if value, ok := os.LookupEnv(key); !ok || strings.TrimSpace(value) == "" {
				panic(fmt.Errorf("release 模式必须显式设置 %s（true/false，生产目标值见 .env.example）", key))
			}
		}
	}

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
		if len([]byte(jwtSecret)) < 32 {
			panic(fmt.Errorf("生产环境 JWT_SECRET 长度至少为 32 字节"))
		}
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
	allowMissingVersionHeaders := !releaseMode
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
		if releaseMode {
			legalConsentEnforcement = "hard"
		} else {
			legalConsentEnforcement = "soft"
		}
	}
	if legalConsentEnforcement != "off" && legalConsentEnforcement != "soft" && legalConsentEnforcement != "hard" {
		panic(fmt.Errorf("LEGAL_CONSENT_ENFORCEMENT 只能是 off、soft 或 hard"))
	}
	if releaseMode && legalConsentEnforcement != "hard" {
		panic(fmt.Errorf("release 模式必须使用 LEGAL_CONSENT_ENFORCEMENT=hard"))
	}
	androidPackageName := strings.TrimSpace(os.Getenv("ANDROID_PACKAGE_NAME"))
	if androidPackageName == "" {
		androidPackageName = "com.example.shenliyuan"
	}
	androidSigningCertificate := strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(os.Getenv("ANDROID_SIGNING_CERT_SHA256")), ":", ""))
	if androidSigningCertificate != "" && !regexp.MustCompile(`^[0-9A-F]{64}$`).MatchString(androidSigningCertificate) {
		panic(fmt.Errorf("ANDROID_SIGNING_CERT_SHA256 必须是 64 位十六进制 SHA-256 指纹"))
	}
	if releaseMode && androidSigningCertificate == "" {
		panic(fmt.Errorf("release 模式必须设置 ANDROID_SIGNING_CERT_SHA256"))
	}
	androidAAPT2Path := strings.TrimSpace(os.Getenv("ANDROID_AAPT2_PATH"))
	if androidAAPT2Path == "" {
		androidAAPT2Path = "aapt2"
	}
	androidAPKSignerPath := strings.TrimSpace(os.Getenv("ANDROID_APKSIGNER_PATH"))
	if androidAPKSignerPath == "" {
		androidAPKSignerPath = "apksigner"
	}
	appReleaseAllowedMarketHosts := splitNonEmpty(os.Getenv("APP_RELEASE_MARKET_HOST_ALLOWLIST"))
	if len(appReleaseAllowedMarketHosts) == 0 {
		appReleaseAllowedMarketHosts = []string{"appgallery.huawei.com"}
	}
	accountIdentityReadMode, err := parseAccountIdentityReadMode(os.Getenv("ACCOUNT_IDENTITY_READ_MODE"))
	if err != nil {
		panic(err)
	}
	// 退役开关采用显式环境变量，便于 C2/C3 分阶段发布和回滚记录。
	// 最终开关兼容单一部署参数，但不会自动修改数据库或删除历史证据。
	schoolAuthorityRetired := envBool("SCHOOL_AUTHORITY_RETIRED", true)
	schoolDeviceCapabilityCut := envBool("SCHOOL_DEVICE_CAPABILITY_CUT", schoolAuthorityRetired)
	schoolAcademicRoutesRetired := envBool("SCHOOL_ACADEMIC_ROUTES_RETIRED", schoolAuthorityRetired)

	aiEnabled := envBool("AI_ENABLED", false)
	aiProvider := strings.ToLower(strings.TrimSpace(os.Getenv("AI_PROVIDER")))
	if aiProvider == "" || aiProvider == "deepseek" {
		aiProvider = "openai-compatible"
	}
	aiAPIKey := firstNonEmptyEnv("AI_API_KEY", "DEEPSEEK_API_KEY")
	aiBaseURL := strings.TrimRight(firstNonEmptyEnv("AI_BASE_URL", "DEEPSEEK_BASE_URL"), "/")
	if aiBaseURL == "" {
		aiBaseURL = "https://api.openai.com/v1"
	}
	aiChatModel := firstNonEmptyEnv("AI_CHAT_MODEL", "DEEPSEEK_CHAT_MODEL")
	if aiChatModel == "" {
		aiChatModel = "gpt-5.4"
	}
	aiRequestTimeoutSeconds := envIntInRange("AI_REQUEST_TIMEOUT_SECONDS", 60, 5, 120)
	aiLegacyMaxOutputTokens := envIntInRange("AI_LEGACY_MAX_OUTPUT_TOKENS", 4096, 256, 8192)
	aiMaxToolSteps := envIntInRange("AI_MAX_TOOL_STEPS", 7, 1, 12)
	aiMaxMessageChars := envIntInRange("AI_MAX_MESSAGE_CHARS", 500, 1, 500)
	aiHourlyMessageLimit := envIntInRange("AI_HOURLY_MESSAGE_LIMIT", 3, 1, 100)
	aiUnlimitedStudentIDs := splitNonEmpty(os.Getenv("AI_UNLIMITED_STUDENT_IDS"))
	aiQuotaExemptUserIDs := envPositiveUintList("AI_QUOTA_EXEMPT_USER_IDS")
	aiUserBudgetLimitMicroYuan := envInt64InRange("AI_USER_BUDGET_LIMIT_MICRO_YUAN", 10_000_000, 1, 1_000_000_000)
	aiReserveMicroYuan := envInt64InRange("AI_RESERVE_MICRO_YUAN", 20_000, 1, aiUserBudgetLimitMicroYuan)
	aiInputPrice := envInt64InRange("AI_INPUT_PRICE_MICRO_YUAN_PER_MILLION_TOKENS", 4_000_000, 0, 1_000_000_000)
	aiOutputPrice := envInt64InRange("AI_OUTPUT_PRICE_MICRO_YUAN_PER_MILLION_TOKENS", 16_000_000, 0, 1_000_000_000)
	aiPolicyRAGEnabled := envBool("AI_POLICY_RAG_ENABLED", false)
	aiLangChainRAGEnabled := envBool("AI_LANGCHAIN_RAG_ENABLED", false)
	// 灰度和 100% 观察窗口默认保留旧路径，关闭必须是单独的显式评审结果。
	aiLegacyRAGEnabled := envBool("AI_LEGACY_RAG_ENABLED", true)
	rolloutDefault := 0
	if aiLangChainRAGEnabled {
		// 开启新链路但未声明灰度比例时按全量处理，避免部署后静默回落到旧链路。
		rolloutDefault = 100
	}
	aiLangChainRAGRolloutPercent := envIntInRange(
		"AI_LANGCHAIN_RAG_ROLLOUT_PERCENT", rolloutDefault, 0, 100,
	)
	// Agent 灰测必须显式开启，避免仅启用普通校园 AI 时意外进入全量 Agent 路径。
	aiAgentEnabled := envBool("AI_AGENT_ENABLED", false)
	aiAgentRolloutDefault := 0
	if aiAgentEnabled {
		aiAgentRolloutDefault = 100
	}
	aiAgentRolloutPercent := envIntInRange("AI_AGENT_ROLLOUT_PERCENT", aiAgentRolloutDefault, 0, 100)
	aiAgentRolloutUserIDs := envPositiveUintList("AI_AGENT_ROLLOUT_USER_IDS")
	aiAgentAppVersionAllowlist := splitNonEmpty(os.Getenv("AI_AGENT_APP_VERSIONS"))
	aiAgentCapabilityAllowlist := splitNonEmpty(os.Getenv("AI_AGENT_CAPABILITIES"))
	aiAgentModeAllowlist := splitNonEmpty(os.Getenv("AI_AGENT_MODES"))
	aiAgentShadowEnabled := envBool("AI_AGENT_SHADOW_ENABLED", false)
	aiAgentShadowPercent := envIntInRange("AI_AGENT_SHADOW_PERCENT", 0, 0, 100)
	aiAgentActionsEnabled := envBool("AI_AGENT_ACTIONS_ENABLED", true)
	aiAgentPersonalDataEnabled := envBool("AI_AGENT_PERSONAL_DATA_ENABLED", true)
	aiAgentDeepModeEnabled := envBool("AI_AGENT_DEEP_MODE_ENABLED", true)
	aiShadowTraceRetentionDays := envIntInRange("AI_SHADOW_TRACE_RETENTION_DAYS", 14, 1, 90)
	aiFailureTraceRetentionDays := envIntInRange("AI_FAILURE_TRACE_RETENTION_DAYS", 60, 7, 180)
	ragServiceURL := strings.TrimRight(strings.TrimSpace(os.Getenv("RAG_SERVICE_URL")), "/")
	if ragServiceURL == "" {
		ragServiceURL = "http://127.0.0.1:18001"
	}
	ragServiceToken := strings.TrimSpace(os.Getenv("RAG_SERVICE_TOKEN"))
	ragEmbeddingModelVersion := strings.TrimSpace(os.Getenv("RAG_EMBEDDING_MODEL_VERSION"))
	if ragEmbeddingModelVersion == "" {
		ragEmbeddingModelVersion = "paraphrase-multilingual-minilm-l12-v2-384-v1"
	}
	aiExternalMCPEnabled := envBool("AI_EXTERNAL_MCP_ENABLED", false)
	aiExternalMCPTransport := strings.TrimSpace(os.Getenv("AI_EXTERNAL_MCP_TRANSPORT"))
	if aiExternalMCPTransport == "" {
		aiExternalMCPTransport = "local_stdio"
	}
	aiExternalMCPCommand := strings.TrimSpace(os.Getenv("AI_EXTERNAL_MCP_COMMAND"))
	aiExternalMCPToolTimeoutSeconds := envIntInRange("AI_EXTERNAL_MCP_TOOL_TIMEOUT_SECONDS", 90, 5, 120)
	aiExternalMCPMaxCallsPerRun := envIntInRange("AI_EXTERNAL_MCP_MAX_CALLS_PER_RUN", 1, 1, 1)
	aiExternalMCPSshHost := strings.TrimSpace(os.Getenv("AI_EXTERNAL_MCP_SSH_HOST"))
	aiExternalMCPSshPort := envIntInRange("AI_EXTERNAL_MCP_SSH_PORT", 22, 1, 65535)
	aiExternalMCPSshUser := strings.TrimSpace(os.Getenv("AI_EXTERNAL_MCP_SSH_USER"))
	aiExternalMCPSshKeyPath := strings.TrimSpace(os.Getenv("AI_EXTERNAL_MCP_SSH_KEY_PATH"))
	aiExternalMCPKnownHostsPath := strings.TrimSpace(os.Getenv("AI_EXTERNAL_MCP_KNOWN_HOSTS_PATH"))
	aiUnifiedMCPURL := strings.TrimSpace(os.Getenv("AI_UNIFIED_MCP_URL"))
	competitionCatalogV2Enabled := envBool("COMPETITION_CATALOG_V2_ENABLED", false)
	competitionCandidateEngineV2Enabled := envBool("COMPETITION_CANDIDATE_ENGINE_V2_ENABLED", false)
	competitionAIExplanationEnabled := envBool("COMPETITION_AI_EXPLANATION_ENABLED", false)
	syluliveMCPGrant := strings.TrimSpace(os.Getenv("SYLULIVE_MCP_GRANT"))
	if err := validateAIConfig(
		aiEnabled, aiProvider, aiAPIKey,
		aiBaseURL, aiChatModel, aiPolicyRAGEnabled,
		aiLangChainRAGEnabled, aiLegacyRAGEnabled, aiLangChainRAGRolloutPercent,
		ragServiceURL, ragServiceToken,
	); err != nil {
		panic(err)
	}
	if err := validateExternalMCPConfig(
		aiExternalMCPEnabled, aiExternalMCPTransport, aiExternalMCPCommand,
		aiExternalMCPToolTimeoutSeconds, aiExternalMCPMaxCallsPerRun,
		aiExternalMCPSshHost, aiExternalMCPSshPort, aiExternalMCPSshUser,
		aiExternalMCPSshKeyPath, aiExternalMCPKnownHostsPath,
	); err != nil {
		panic(err)
	}

	return &Config{
		JWTSecret:                        jwtSecret,
		DSN:                              dsn,
		UploadDir:                        uploadDir,
		ImageVariantWorkerEnabled:        imageVariantWorkerEnabled,
		HomeFeedPersonalizationShadow:    homeFeedShadow(),
		HomeFeedPersonalizationPercent:   homeFeedPercent(),
		HomeFeedV5PersonalizationShadow:  homeFeedV5Shadow(),
		HomeFeedV5PersonalizationPercent: homeFeedV5Percent(),
		CompetitionAwardEvidenceDir:      competitionAwardEvidenceDir,
		ExamPaperDir:                     examPaperDir,
		ExamPaperStorageMode:             examPaperStorageMode,
		ExamPaperStorageBaseURL:          examPaperStorageBaseURL,
		ExamPaperStorageSigningSecret:    examPaperStorageSigningSecret,
		ExamPaperStorageReceiptSecret:    examPaperStorageReceiptSecret,
		MaxFileSize:                      10 * 1024 * 1024, // 10MB
		EduServiceURL:                    eduServiceURL,
		SMTPHost:                         smtpHost,
		SMTPPort:                         smtpPort,
		SMTPUser:                         smtpUser,
		SMTPPass:                         smtpPass,
		SMTPFrom:                         smtpFrom,
		JPushAppKey:                      jpushAppKey,
		JPushMasterSecret:                jpushMasterSecret,
		SuperAdminID:                     superAdminID,
		SuperAdminPass:                   superAdminPass,

		AIEnabled:                              aiEnabled,
		AIProvider:                             aiProvider,
		AIAPIKey:                               aiAPIKey,
		AIBaseURL:                              aiBaseURL,
		AIChatModel:                            aiChatModel,
		AIRequestTimeoutSeconds:                aiRequestTimeoutSeconds,
		AILegacyMaxOutputTokens:                aiLegacyMaxOutputTokens,
		AIMaxToolSteps:                         aiMaxToolSteps,
		AIMaxMessageChars:                      aiMaxMessageChars,
		AIHourlyMessageLimit:                   aiHourlyMessageLimit,
		AIUnlimitedStudentIDs:                  aiUnlimitedStudentIDs,
		AIQuotaExemptUserIDs:                   aiQuotaExemptUserIDs,
		AIUserBudgetLimitMicroYuan:             aiUserBudgetLimitMicroYuan,
		AIReserveMicroYuan:                     aiReserveMicroYuan,
		AIInputPriceMicroYuanPerMillionTokens:  aiInputPrice,
		AIOutputPriceMicroYuanPerMillionTokens: aiOutputPrice,
		AIPolicyRAGEnabled:                     aiPolicyRAGEnabled,
		AILangChainRAGEnabled:                  aiLangChainRAGEnabled,
		AILangChainRAGRolloutPercent:           aiLangChainRAGRolloutPercent,
		AILegacyRAGEnabled:                     aiLegacyRAGEnabled,
		AIAgentEnabled:                         aiAgentEnabled,
		AIAgentRolloutPercent:                  aiAgentRolloutPercent,
		AIAgentRolloutUserIDs:                  aiAgentRolloutUserIDs,
		AIAgentAppVersionAllowlist:             aiAgentAppVersionAllowlist,
		AIAgentCapabilityAllowlist:             aiAgentCapabilityAllowlist,
		AIAgentModeAllowlist:                   aiAgentModeAllowlist,
		AIAgentShadowEnabled:                   aiAgentShadowEnabled,
		AIAgentShadowPercent:                   aiAgentShadowPercent,
		AIAgentActionsEnabled:                  aiAgentActionsEnabled,
		AIAgentPersonalDataEnabled:             aiAgentPersonalDataEnabled,
		AIAgentDeepModeEnabled:                 aiAgentDeepModeEnabled,
		AIShadowTraceRetentionDays:             aiShadowTraceRetentionDays,
		AIFailureTraceRetentionDays:            aiFailureTraceRetentionDays,
		RAGServiceURL:                          ragServiceURL,
		RAGServiceToken:                        ragServiceToken,
		RAGEmbeddingModelVersion:               ragEmbeddingModelVersion,
		AIExternalMCPEnabled:                   aiExternalMCPEnabled,
		AIExternalMCPTransport:                 aiExternalMCPTransport,
		AIExternalMCPCommand:                   aiExternalMCPCommand,
		AIExternalMCPToolTimeoutSeconds:        aiExternalMCPToolTimeoutSeconds,
		AIExternalMCPMaxCallsPerRun:            aiExternalMCPMaxCallsPerRun,
		AIExternalMCPSshHost:                   aiExternalMCPSshHost,
		AIExternalMCPSshPort:                   aiExternalMCPSshPort,
		AIExternalMCPSshUser:                   aiExternalMCPSshUser,
		AIExternalMCPSshKeyPath:                aiExternalMCPSshKeyPath,
		AIExternalMCPKnownHostsPath:            aiExternalMCPKnownHostsPath,
		AIUnifiedMCPURL:                        aiUnifiedMCPURL,

		EduServiceToken:        eduServiceToken,
		JWCSyncEnabled:         jwcSyncEnabled,
		JWCSyncIntervalMinutes: jwcSyncIntervalMinutes,

		AppReleaseDir:                       appReleaseDir,
		AppReleaseMaxSize:                   int64(appReleaseMaxSizeMB) * 1024 * 1024,
		AppUpdateEnforcementEnabled:         appUpdateEnforcementEnabled,
		AllowMissingVersionHeaders:          allowMissingVersionHeaders,
		AppReleaseUseAccelRedirect:          appReleaseUseAccelRedirect,
		AppReleaseAccelPrefix:               appReleaseAccelPrefix,
		LegalConsentEnforcement:             legalConsentEnforcement,
		AccountIdentityReadMode:             accountIdentityReadMode,
		SchoolDeviceCapabilityCut:           schoolDeviceCapabilityCut,
		SchoolAcademicRoutesRetired:         schoolAcademicRoutesRetired,
		AndroidPackageName:                  androidPackageName,
		AndroidSigningCertificate:           androidSigningCertificate,
		AndroidAAPT2Path:                    androidAAPT2Path,
		AndroidAPKSignerPath:                androidAPKSignerPath,
		AppReleaseAllowedMarketHosts:        appReleaseAllowedMarketHosts,
		CompetitionCatalogV2Enabled:         competitionCatalogV2Enabled,
		CompetitionCandidateEngineV2Enabled: competitionCandidateEngineV2Enabled,
		CompetitionAIExplanationEnabled:     competitionAIExplanationEnabled,
		SyluliveMCPGrant:                    syluliveMCPGrant,
		ReviewEnabled:                       envBool("REVIEW_ENABLED", false),
	}
}

func parseAccountIdentityReadMode(value string) (string, error) {
	mode := strings.ToLower(strings.TrimSpace(value))
	if mode == "" {
		return "legacy", nil
	}
	if mode != "legacy" && mode != "identity" {
		return "", fmt.Errorf("ACCOUNT_IDENTITY_READ_MODE 只能是 legacy 或 identity")
	}
	return mode, nil
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

func requireReleaseTrue(names ...string) {
	for _, name := range names {
		value, ok := os.LookupEnv(name)
		if !ok || strings.TrimSpace(value) == "" {
			panic(fmt.Errorf("release 模式必须显式设置 %s=true", name))
		}
		parsed, err := strconv.ParseBool(strings.TrimSpace(value))
		if err != nil || !parsed {
			panic(fmt.Errorf("release 模式必须设置 %s=true", name))
		}
	}
}

func firstNonEmptyEnv(names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(os.Getenv(name)); value != "" {
			return value
		}
	}
	return ""
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

func envPositiveUintList(name string) []uint {
	parts := splitNonEmpty(os.Getenv(name))
	result := make([]uint, 0, len(parts))
	for _, part := range parts {
		value, err := strconv.ParseUint(part, 10, strconv.IntSize)
		if err != nil || value == 0 {
			panic(fmt.Errorf("%s 只能包含逗号分隔的正整数用户 ID", name))
		}
		result = append(result, uint(value))
	}
	return result
}

func validateAIConfig(
	enabled bool,
	provider, apiKey, baseURL, model string,
	policyRAGEnabled, langChainRAGEnabled, legacyRAGEnabled bool,
	langChainRolloutPercent int,
	ragServiceURL, ragServiceToken string,
) error {
	if provider != "openai-compatible" && provider != "mock" {
		return fmt.Errorf("AI_PROVIDER 只能是 openai-compatible 或 mock")
	}
	if !enabled {
		return nil
	}
	if provider == "openai-compatible" && apiKey == "" && legacyRAGEnabled {
		return fmt.Errorf("AI_ENABLED=true 且 AI_PROVIDER=openai-compatible 时必须设置 AI_API_KEY")
	}
	if strings.TrimSpace(model) == "" {
		return fmt.Errorf("AI_ENABLED=true 时模型名称不能为空")
	}
	if model != "gpt-5.4" && model != "gpt-5.4-mini" {
		return fmt.Errorf("AI_CHAT_MODEL 只能是已审核的 gpt-5.4 或 gpt-5.4-mini")
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("AI_BASE_URL 必须是无用户信息的 HTTPS 地址")
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
	if !langChainRAGEnabled && langChainRolloutPercent != 0 {
		return fmt.Errorf("AI_LANGCHAIN_RAG_ENABLED=false 时灰度比例必须为 0")
	}
	if policyRAGEnabled && !langChainRAGEnabled && !legacyRAGEnabled {
		return fmt.Errorf("政策 RAG 必须至少启用 LangChain 或旧 Go 路径之一")
	}
	if langChainRAGEnabled && langChainRolloutPercent < 100 && !legacyRAGEnabled {
		return fmt.Errorf("LangChain 未全量时必须启用 AI_LEGACY_RAG_ENABLED 作为未命中账号路径")
	}
	return nil
}

var externalMCPSSHUserPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]{0,31}$`)
var externalMCPSSHHostPattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)

// validateExternalMCPConfig 保证 Go 只会启动固定 stdio 子进程或受限 SSH 通道，
// 不接受可由 Shell 解释的地址、命令片段或相对密钥路径。
func validateExternalMCPConfig(enabled bool, transport, command string, timeoutSeconds, maxCalls int, sshHost string, sshPort int, sshUser, sshKeyPath, knownHostsPath string) error {
	if !enabled {
		return nil
	}
	if timeoutSeconds < 5 || timeoutSeconds > 120 {
		return fmt.Errorf("AI_EXTERNAL_MCP_TOOL_TIMEOUT_SECONDS 必须在 5 到 120 之间")
	}
	if maxCalls != 1 {
		return fmt.Errorf("AI_EXTERNAL_MCP_MAX_CALLS_PER_RUN 当前必须为 1")
	}
	switch transport {
	case "local_stdio":
		return validateExternalMCPAbsolutePath("AI_EXTERNAL_MCP_COMMAND", command)
	case "ssh_stdio":
		if !validExternalMCPSSHHost(sshHost) {
			return fmt.Errorf("AI_EXTERNAL_MCP_SSH_HOST 无效")
		}
		if sshPort < 1 || sshPort > 65535 {
			return fmt.Errorf("AI_EXTERNAL_MCP_SSH_PORT 必须在 1 到 65535 之间")
		}
		if !externalMCPSSHUserPattern.MatchString(strings.TrimSpace(sshUser)) {
			return fmt.Errorf("AI_EXTERNAL_MCP_SSH_USER 无效")
		}
		if err := validateExternalMCPAbsolutePath("AI_EXTERNAL_MCP_SSH_KEY_PATH", sshKeyPath); err != nil {
			return err
		}
		return validateExternalMCPAbsolutePath("AI_EXTERNAL_MCP_KNOWN_HOSTS_PATH", knownHostsPath)
	default:
		return fmt.Errorf("AI_EXTERNAL_MCP_TRANSPORT 只能是 local_stdio 或 ssh_stdio")
	}
}

func validateExternalMCPAbsolutePath(name, value string) error {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "\x00\r\n") || !filepath.IsAbs(value) {
		return fmt.Errorf("%s 必须是绝对路径", name)
	}
	return nil
}

func validExternalMCPSSHHost(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "@/\\\x00\r\n") {
		return false
	}
	if net.ParseIP(value) != nil {
		return true
	}
	// IPv6 使用裸地址传入，SSH 命令构造时才添加方括号，防止主机名混入端口。
	if strings.Contains(value, ":") {
		return false
	}
	return externalMCPSSHHostPattern.MatchString(value) && !strings.Contains(value, "..")
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

// homeFeedShadow 读取 FEED-5 个性化 shadow 开关（默认开启：计算 + trace，不改排序）。
func homeFeedShadow() bool {
	v := os.Getenv("HOME_FEED_PERSONALIZATION_SHADOW")
	return !(v == "0" || strings.EqualFold(v, "false"))
}

// homeFeedPercent 读取 FEED-5 个性化 active rollout 百分比（默认 0）。
func homeFeedPercent() int {
	v := os.Getenv("HOME_FEED_PERSONALIZATION_PERCENT")
	if v == "" {
		return 0
	}
	p, err := strconv.Atoi(v)
	if err != nil || p < 0 {
		return 0
	}
	if p > 100 {
		return 100
	}
	return p
}

// homeFeedV5Shadow 读取 FEED-V5 个性化 shadow 开关（默认关闭：V5 不主动上线）。
func homeFeedV5Shadow() bool {
	v := os.Getenv("HOME_FEED_V5_PERSONALIZATION_SHADOW")
	return v == "1" || strings.EqualFold(v, "true")
}

// homeFeedV5Percent 读取 FEED-V5 个性化 active rollout 百分比（默认 0）。
func homeFeedV5Percent() int {
	v := os.Getenv("HOME_FEED_V5_PERSONALIZATION_PERCENT")
	if v == "" {
		return 0
	}
	p, err := strconv.Atoi(v)
	if err != nil || p < 0 {
		return 0
	}
	if p > 100 {
		return 100
	}
	return p
}
