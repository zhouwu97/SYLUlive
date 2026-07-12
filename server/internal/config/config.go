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

	EduServiceToken        string // Python 教务服务共享密钥
	JWCSyncEnabled         bool   // 校园资讯同步开关
	JWCSyncIntervalMinutes int    // 校园资讯同步间隔(分钟)
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
				os.Setenv(strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]))
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
		if err := ensurePrivateDirOutsidePublicUploads(uploadDir, examPaperDir); err != nil {
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

	return &Config{
		JWTSecret:                     jwtSecret,
		DSN:                           dsn,
		UploadDir:                     uploadDir,
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

		EduServiceToken:        eduServiceToken,
		JWCSyncEnabled:         jwcSyncEnabled,
		JWCSyncIntervalMinutes: jwcSyncIntervalMinutes,
	}
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
		if err != nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.Hostname() == "" || parsed.User != nil || parsed.Fragment != "" {
			return fmt.Errorf("生产环境 EXAM_PAPER_STORAGE_BASE_URL 必须使用 HTTPS")
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

func ensurePrivateDirOutsidePublicUploads(uploadDir, examPaperDir string) error {
	uploadAbs, err := filepath.Abs(filepath.Clean(uploadDir))
	if err != nil {
		return fmt.Errorf("解析 UPLOAD_DIR 失败: %w", err)
	}
	examAbs, err := filepath.Abs(filepath.Clean(examPaperDir))
	if err != nil {
		return fmt.Errorf("解析 EXAM_PAPER_DIR 失败: %w", err)
	}
	relative, err := filepath.Rel(uploadAbs, examAbs)
	if err != nil {
		return fmt.Errorf("校验试卷私有目录失败: %w", err)
	}
	if relative == "." || (!strings.HasPrefix(relative, "..") && !filepath.IsAbs(relative)) {
		return fmt.Errorf("EXAM_PAPER_DIR 不能等于或位于公开 UPLOAD_DIR 内")
	}
	return nil
}
