package config

import (
	"fmt"
	"os"
)

// Config 应用配置
type Config struct {
	JWTSecret            string // JWT密钥
	DSN                  string // 数据库连接字符串
	SuperAdminDefaultPwd string // 超级管理员默认密码
	UploadDir            string // 文件上传目录
	MaxFileSize          int64  // 最大文件大小(字节)
	EduServiceURL        string // Python教务服务地址
}

// Load 从环境变量加载配置
func Load() *Config {
	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		jwtSecret = "dev-only-secret-do-not-use-in-production"
	}

	dsn := os.Getenv("DSN")
	if dsn == "" {
		dsn = "./shenliyuan.db"
	}

	superAdminPwd := os.Getenv("SUPER_ADMIN_DEFAULT_PASSWORD")
	if superAdminPwd == "" {
		superAdminPwd = "dev-only-password-do-not-use-in-production"
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
		if superAdminPwd == "dev-only-password-do-not-use-in-production" {
			panic(fmt.Errorf("生产环境必须设置 SUPER_ADMIN_DEFAULT_PASSWORD 环境变量"))
		}
	}

	eduServiceURL := os.Getenv("EDU_SERVICE_URL")
	if eduServiceURL == "" {
		eduServiceURL = "https://nominalistically-subpeduncled-alexandria.ngrok-free.dev"
	}

	return &Config{
		JWTSecret:            jwtSecret,
		DSN:                  dsn,
		SuperAdminDefaultPwd: superAdminPwd,
		UploadDir:            uploadDir,
		MaxFileSize:          2 * 1024 * 1024, // 2MB
		EduServiceURL:        eduServiceURL,
	}
}
