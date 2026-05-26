package config

import (
	"fmt"
	"os"
	"strings"
)

// Config 应用配置
type Config struct {
	JWTSecret        string // JWT密钥
	DSN              string // 数据库连接字符串
	UploadDir        string // 文件上传目录
	MaxFileSize      int64  // 最大文件大小(字节)
	EduServiceURL    string // Python教务服务地址
	SMTPHost         string // SMTP 地址
	SMTPPort         string // SMTP 端口
	SMTPUser         string // SMTP 用户名
	SMTPPass         string // SMTP 密码/授权码
	SMTPFrom         string // 发件人邮箱
	JPushAppKey      string // 极光推送 AppKey
	JPushMasterSecret string // 极光推送 MasterSecret
	SuperAdminID     string // 超级管理员账号
	SuperAdminPass   string // 超级管理员密码
	DeepSeekAPIKey   string // DeepSeek API 密钥
	DeepSeekBaseURL  string // DeepSeek API 基础路径
}

// Load 从环境变量加载配置
func Load() *Config {
	// 强制读取 /opt/shenliyuan/.env
	content, err := os.ReadFile("/opt/shenliyuan/.env")
	if err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "DSN=") {
				os.Setenv("DSN", strings.TrimPrefix(line, "DSN="))
			} else if strings.HasPrefix(line, "JWT_SECRET=") {
				os.Setenv("JWT_SECRET", strings.TrimPrefix(line, "JWT_SECRET="))
			}
		}
	}

	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		jwtSecret = "dev-only-secret-do-not-use-in-production"
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

	// 生产环境检查
	if os.Getenv("GIN_MODE") == "release" {
		if jwtSecret == "dev-only-secret-do-not-use-in-production" {
			panic(fmt.Errorf("生产环境必须设置 JWT_SECRET 环境变量"))
		}
	}

	eduServiceURL := os.Getenv("EDU_SERVICE_URL")
	if eduServiceURL == "" {
		eduServiceURL = "http://101.42.27.44:8000"
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
		superAdminID = "admin" // 默认超级管理员账号
	}

	superAdminPass := os.Getenv("SUPER_ADMIN_PASSWORD")
	if superAdminPass == "" {
		superAdminPass = "admin123" // 默认超级管理员密码
	}

	deepSeekAPIKey := os.Getenv("DEEPSEEK_API_KEY")
	deepSeekBaseURL := os.Getenv("DEEPSEEK_BASE_URL")
	if deepSeekBaseURL == "" {
		deepSeekBaseURL = "https://api.deepseek.com/v1"
	}

	return &Config{
		JWTSecret:         jwtSecret,
		DSN:               dsn,
		UploadDir:         uploadDir,
		MaxFileSize:       10 * 1024 * 1024, // 10MB
		EduServiceURL:     eduServiceURL,
		SMTPHost:          smtpHost,
		SMTPPort:          smtpPort,
		SMTPUser:          smtpUser,
		SMTPPass:          smtpPass,
		SMTPFrom:          smtpFrom,
		JPushAppKey:       jpushAppKey,
		JPushMasterSecret: jpushMasterSecret,
		SuperAdminID:      superAdminID,
		SuperAdminPass:    superAdminPass,
		DeepSeekAPIKey:    deepSeekAPIKey,
		DeepSeekBaseURL:   deepSeekBaseURL,
	}
}
