package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func main() {
	packagePath := flag.String("package", "", "发布记录批准的内置 .sltheme 包")
	authorID := flag.Uint("author-id", 0, "负责署名的应用超级管理员 ID")
	releaseCommit := flag.String("release-commit", "", "包含该主题的 App 完整提交 SHA")
	description := flag.String("description", "", "商城简介，可用于补充素材署名")
	flag.Parse()
	if *packagePath == "" || *authorID == 0 || *releaseCommit == "" || flag.NArg() != 0 {
		flag.Usage()
		os.Exit(2)
	}
	if err := publish(*packagePath, *authorID, *releaseCommit, *description); err != nil {
		log.Fatal(err)
	}
}

func publish(packagePath string, authorID uint, releaseCommit, description string) error {
	f, err := os.Open(packagePath)
	if err != nil {
		return fmt.Errorf("打开主题包: %w", err)
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, services.ThemePackMaxPackageBytes+1))
	if err != nil {
		return fmt.Errorf("读取主题包: %w", err)
	}

	cfg := config.Load()
	db, err := gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		return fmt.Errorf("连接发布数据库失败")
	}
	pool, err := db.DB()
	if err != nil {
		return fmt.Errorf("获取发布数据库连接失败")
	}
	defer pool.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	var overrides services.ThemeMetadataOverrides
	if description != "" {
		overrides.Description = &description
	}
	pack, err := services.NewThemePackService(db, cfg.UploadDir).
		PublishOfficialRelease(ctx, authorID, releaseCommit, overrides, raw)
	if err != nil {
		return err
	}
	if pack.Status != models.ThemeStatusApproved || pack.Source != models.ThemeSourceOfficial {
		return fmt.Errorf("该发布提交对应的主题状态为 %s", pack.Status)
	}
	return json.NewEncoder(os.Stdout).Encode(pack)
}
