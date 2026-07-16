package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"

	"shenliyuan/internal/handlers"
	"shenliyuan/internal/services"
)

type paperStorageConfig struct {
	Listen                   string
	Dir                      string
	SigningSecret            string
	ReceiptSecret            string
	MaxConcurrentValidations int
}

func loadPaperStorageConfig(getenv func(string) string) (paperStorageConfig, error) {
	config := paperStorageConfig{
		Listen:                   strings.TrimSpace(getenv("PAPER_STORAGE_LISTEN")),
		Dir:                      strings.TrimSpace(getenv("PAPER_STORAGE_DIR")),
		SigningSecret:            strings.TrimSpace(getenv("PAPER_STORAGE_SIGNING_SECRET")),
		ReceiptSecret:            strings.TrimSpace(getenv("PAPER_STORAGE_RECEIPT_SECRET")),
		MaxConcurrentValidations: 2,
	}
	concurrencyText := strings.TrimSpace(getenv("PAPER_STORAGE_MAX_CONCURRENT_VALIDATIONS"))
	if config.Listen == "" {
		config.Listen = ":8081"
	}
	if config.Dir == "" {
		config.Dir = "./paper_storage"
	}
	if config.SigningSecret == "" || config.ReceiptSecret == "" {
		return paperStorageConfig{}, fmt.Errorf("存储授权密钥和回执密钥均不能为空")
	}
	if len([]byte(config.SigningSecret)) < 32 || len([]byte(config.ReceiptSecret)) < 32 {
		return paperStorageConfig{}, fmt.Errorf("存储授权密钥和回执密钥长度不足")
	}
	if config.SigningSecret == config.ReceiptSecret {
		return paperStorageConfig{}, fmt.Errorf("存储授权密钥和回执密钥必须不同")
	}
	if concurrencyText != "" {
		value, err := strconv.Atoi(concurrencyText)
		if err != nil || value <= 0 {
			return paperStorageConfig{}, fmt.Errorf("并发校验数必须为正整数")
		}
		config.MaxConcurrentValidations = value
	}
	return config, nil
}

func run(ctx context.Context, config paperStorageConfig) error {
	files, err := services.NewExamPaperFileService(config.Dir)
	if err != nil {
		return err
	}
	grantSigner, err := services.NewExamPaperStorageSigner(config.SigningSecret, time.Now)
	if err != nil {
		return err
	}
	receiptSigner, err := services.NewExamPaperStorageSigner(config.ReceiptSecret, time.Now)
	if err != nil {
		return err
	}

	gin.SetMode(gin.ReleaseMode)
	router := gin.New()
	router.Use(gin.Recovery())
	handler := handlers.NewPaperStorageHandler(files, grantSigner, receiptSigner, config.MaxConcurrentValidations)
	handlers.RegisterPaperStorageRoutes(router, handler)

	listener, err := net.Listen("tcp", config.Listen)
	if err != nil {
		return fmt.Errorf("监听文件服务失败: %w", err)
	}
	server := newPaperStorageServer(router)
	serveErrors := make(chan error, 1)
	go func() {
		serveErrors <- server.Serve(listener)
	}()

	select {
	case err := <-serveErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownContext); err != nil {
			return fmt.Errorf("关闭文件服务失败: %w", err)
		}
		if err := <-serveErrors; err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

func newPaperStorageServer(handler http.Handler) *http.Server {
	return &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       5 * time.Minute,
		IdleTimeout:       60 * time.Second,
	}
}

func main() {
	config, err := loadPaperStorageConfig(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, config); err != nil {
		log.Fatal(err)
	}
}
