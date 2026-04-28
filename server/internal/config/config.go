package config

import (
	"os"
)

// Config 应用配置
type Config struct {
	JWTSecret            string // JWT密钥
	DSN                  string // 数据库连接字符串
	SuperAdminDefaultPwd string // 超级管理员默认密码
	UploadDir            string // 文件上传目录
	MaxFileSize          int64  // 最大文件大小(字节)
}

// Load 从环境变量加载配置
func Load() *Config {
	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		jwtSecret = "xiaoyuan-default-secret-change-in-production"
	}

	dsn := os.Getenv("DSN")
	if dsn == "" {
		dsn = "./xiaoyuan.db"
	}

	superAdminPwd := os.Getenv("SUPER_ADMIN_DEFAULT_PASSWORD")
	if superAdminPwd == "" {
		superAdminPwd = "super123456"
	}

	uploadDir := os.Getenv("UPLOAD_DIR")
	if uploadDir == "" {
		uploadDir = "./uploads"
	}

	return &Config{
		JWTSecret:            jwtSecret,
		DSN:                  dsn,
		SuperAdminDefaultPwd: superAdminPwd,
		UploadDir:            uploadDir,
		MaxFileSize:          2 * 1024 * 1024, // 2MB
	}
}