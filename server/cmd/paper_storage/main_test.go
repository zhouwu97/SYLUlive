package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestPaperStorageLoadConfigUsesDefaultsAndOnlyAllowedEnvironment(t *testing.T) {
	values := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET": "grant-secret-012345678901234567890",
		"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret-012345678901234567890",
		"DATABASE_DSN":                 "不得读取",
		"JWT_SECRET":                   "不得读取",
	}
	read := map[string]bool{}
	config, err := loadPaperStorageConfig(func(key string) string {
		read[key] = true
		return values[key]
	})
	if err != nil {
		t.Fatalf("加载配置失败: %v", err)
	}
	if config.Listen != ":8081" || config.Dir != "./paper_storage" || config.MaxConcurrentValidations != 2 ||
		!config.UseAccelRedirect || config.WarningPercent != 70 || config.UploadStopPercent != 85 || config.ReadonlyPercent != 95 {
		t.Fatalf("默认配置错误: %+v", config)
	}
	for _, forbidden := range []string{"DATABASE_DSN", "JWT_SECRET"} {
		if read[forbidden] {
			t.Fatalf("独立文件服务不得读取 %s", forbidden)
		}
	}
	if len(read) != 9 {
		t.Fatalf("读取了非允许环境变量: %v", read)
	}
}

func TestPaperStorageLoadConfigRejectsMissingSecretsAndInvalidConcurrency(t *testing.T) {
	base := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET": "grant-secret-012345678901234567890",
		"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret-012345678901234567890",
	}
	for _, tt := range []struct{ name, key, value string }{
		{name: "缺少授权密钥", key: "PAPER_STORAGE_SIGNING_SECRET", value: ""},
		{name: "缺少回执密钥", key: "PAPER_STORAGE_RECEIPT_SECRET", value: ""},
		{name: "并发数非数字", key: "PAPER_STORAGE_MAX_CONCURRENT_VALIDATIONS", value: "bad"},
		{name: "并发数非正数", key: "PAPER_STORAGE_MAX_CONCURRENT_VALIDATIONS", value: "0"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			values := map[string]string{}
			for key, value := range base {
				values[key] = value
			}
			values[tt.key] = tt.value
			if _, err := loadPaperStorageConfig(func(key string) string { return values[key] }); err == nil {
				t.Fatal("非法配置应被拒绝")
			}
		})
	}
}

func TestPaperStorageLoadConfigReadsColocatedPolicy(t *testing.T) {
	values := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET":      "grant-secret-012345678901234567890",
		"PAPER_STORAGE_RECEIPT_SECRET":      "receipt-secret-012345678901234567890",
		"PAPER_STORAGE_USE_ACCEL_REDIRECT":  "false",
		"PAPER_STORAGE_WARNING_PERCENT":     "60",
		"PAPER_STORAGE_UPLOAD_STOP_PERCENT": "75",
		"PAPER_STORAGE_READONLY_PERCENT":    "85",
	}
	config, err := loadPaperStorageConfig(func(key string) string { return values[key] })
	if err != nil {
		t.Fatalf("加载同机策略失败: %v", err)
	}
	if config.UseAccelRedirect || config.WarningPercent != 60 || config.UploadStopPercent != 75 || config.ReadonlyPercent != 85 {
		t.Fatalf("同机策略错误: %+v", config)
	}
}

func TestPaperStorageLoadConfigRejectsInvalidDiskPolicy(t *testing.T) {
	base := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET": "grant-secret-012345678901234567890",
		"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret-012345678901234567890",
	}
	for _, values := range []map[string]string{
		{"PAPER_STORAGE_USE_ACCEL_REDIRECT": "yes"},
		{"PAPER_STORAGE_WARNING_PERCENT": "0"},
		{"PAPER_STORAGE_UPLOAD_STOP_PERCENT": "101"},
		{"PAPER_STORAGE_WARNING_PERCENT": "80", "PAPER_STORAGE_UPLOAD_STOP_PERCENT": "70"},
	} {
		for key, value := range base {
			values[key] = value
		}
		if _, err := loadPaperStorageConfig(func(key string) string { return values[key] }); err == nil {
			t.Fatalf("非法磁盘策略应被拒绝: %v", values)
		}
	}
}

func TestPaperStorageLoadConfigRejectsEqualSecretsIncludingWhitespace(t *testing.T) {
	for _, tt := range []struct {
		name, signing, receipt string
	}{
		{name: "完全相同", signing: "same-secret", receipt: "same-secret"},
		{name: "空白差异", signing: "  same-secret ", receipt: "same-secret"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			values := map[string]string{
				"PAPER_STORAGE_SIGNING_SECRET": tt.signing,
				"PAPER_STORAGE_RECEIPT_SECRET": tt.receipt,
			}
			_, err := loadPaperStorageConfig(func(key string) string { return values[key] })
			if err == nil {
				t.Fatal("相同签名密钥应被拒绝")
			}
			if strings.Contains(err.Error(), "same-secret") {
				t.Fatalf("错误不应泄露密钥: %v", err)
			}
		})
	}
	config, err := loadPaperStorageConfig(func(key string) string {
		return map[string]string{
			"PAPER_STORAGE_SIGNING_SECRET": "grant-secret-012345678901234567890",
			"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret-012345678901234567890",
		}[key]
	})
	if err != nil || config.SigningSecret == config.ReceiptSecret {
		t.Fatalf("不同密钥应通过: config=%+v err=%v", config, err)
	}
}

func TestPaperStorageRunHonorsCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	config := paperStorageConfig{
		Listen: "127.0.0.1:0", Dir: t.TempDir(),
		SigningSecret: "grant-secret-012345678901234567890", ReceiptSecret: "receipt-secret-012345678901234567890", MaxConcurrentValidations: 1,
	}
	if err := run(ctx, config); err != nil {
		t.Fatalf("优雅关闭失败: %v", err)
	}
}

func TestPaperStorageLoadConfigRejectsShortSecrets(t *testing.T) {
	values := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET": "short",
		"PAPER_STORAGE_RECEIPT_SECRET": "another-short",
	}
	if _, err := loadPaperStorageConfig(func(key string) string { return values[key] }); err == nil {
		t.Fatal("短密钥应被拒绝")
	}
}

func TestPaperStorageServerHasUploadTimeouts(t *testing.T) {
	server := newPaperStorageServer(gin.New())
	if server.ReadTimeout < 5*time.Minute || server.IdleTimeout <= 0 {
		t.Fatalf("server 超时配置不足: read=%v idle=%v", server.ReadTimeout, server.IdleTimeout)
	}
}

func TestPaperStorageMainHasNoDatabaseOrJWTDependency(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("main.go"))
	if err != nil {
		t.Fatalf("读取 main.go 失败: %v", err)
	}
	for _, forbidden := range []string{"config.Load", "gorm", "DATABASE_DSN", "JWT_SECRET"} {
		if strings.Contains(string(source), forbidden) {
			t.Fatalf("独立入口包含禁止依赖 %q", forbidden)
		}
	}
}
