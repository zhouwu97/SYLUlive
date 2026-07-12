package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPaperStorageLoadConfigUsesDefaultsAndOnlyAllowedEnvironment(t *testing.T) {
	values := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET": "grant-secret",
		"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret",
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
	if config.Listen != ":8081" || config.Dir != "./paper_storage" || config.MaxConcurrentValidations != 2 {
		t.Fatalf("默认配置错误: %+v", config)
	}
	for _, forbidden := range []string{"DATABASE_DSN", "JWT_SECRET"} {
		if read[forbidden] {
			t.Fatalf("独立文件服务不得读取 %s", forbidden)
		}
	}
	if len(read) != 5 {
		t.Fatalf("读取了非允许环境变量: %v", read)
	}
}

func TestPaperStorageLoadConfigRejectsMissingSecretsAndInvalidConcurrency(t *testing.T) {
	base := map[string]string{
		"PAPER_STORAGE_SIGNING_SECRET": "grant-secret",
		"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret",
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
			"PAPER_STORAGE_SIGNING_SECRET": "grant-secret",
			"PAPER_STORAGE_RECEIPT_SECRET": "receipt-secret",
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
		SigningSecret: "grant-secret", ReceiptSecret: "receipt-secret", MaxConcurrentValidations: 1,
	}
	if err := run(ctx, config); err != nil {
		t.Fatalf("优雅关闭失败: %v", err)
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
