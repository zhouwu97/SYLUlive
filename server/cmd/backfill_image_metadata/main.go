// 回填历史图片元数据：为 width/height 为 0 的 image/* 文件补齐规范宽高，
// 并按真实内容纠正 MIME（仅更新数据库 width/height/mime_type 字段，不重命名物理文件与不变更原有 Path/URL，保持历史引用有效）。
//
// 用法：
//
//	go run ./cmd/backfill_image_metadata --dry-run
//	go run ./cmd/backfill_image_metadata --limit 500
package main

import (
	"flag"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

func main() {
	dryRun := flag.Bool("dry-run", false, "只统计不改写")
	limit := flag.Int("limit", 0, "最多处理条数，0 表示全部")
	flag.Parse()

	cfg := config.Load()
	db := openDB(cfg.DSN)

	var files []models.File
	q := db.Where("mime_type LIKE 'image/%' AND (width = 0 OR height = 0)")
	if *limit > 0 {
		q = q.Limit(*limit)
	}
	if err := q.Order("id ASC").Find(&files).Error; err != nil {
		log.Fatalf("查询待回填文件失败: %v", err)
	}

	counts := map[string]int{
		"updated":      0,
		"missing_file": 0,
		"invalid_path": 0,
		"decode_failed": 0,
		"mime_fixed":   0,
	}

	for i := range files {
		f := &files[i]
		fullPath, err := services.ResolveUploadPath(cfg.UploadDir, f.Path)
		if err != nil {
			counts["invalid_path"]++
			log.Printf("[skip] invalid_path id=%d path=%q: %v", f.ID, f.Path, err)
			continue
		}
		fh, err := os.Open(fullPath)
		if err != nil {
			counts["missing_file"]++
			log.Printf("[skip] missing_file id=%d path=%q: %v", f.ID, f.Path, err)
			continue
		}
		header := make([]byte, 512)
		n, _ := fh.Read(header)
		if _, err := fh.Seek(0, io.SeekStart); err != nil {
			fh.Close()
			counts["decode_failed"]++
			continue
		}
		cfgImg, _, err := image.DecodeConfig(fh)
		fh.Close()
		if err != nil || cfgImg.Width <= 0 || cfgImg.Height <= 0 {
			counts["decode_failed"]++
			log.Printf("[skip] decode_failed id=%d path=%q: %v", f.ID, f.Path, err)
			continue
		}
		detectedMime := http.DetectContentType(header[:n])

		updates := map[string]interface{}{
			"width":  cfgImg.Width,
			"height": cfgImg.Height,
		}
		if detectedMime != f.MimeType && isSupportedImage(detectedMime) {
			updates["mime_type"] = detectedMime
			counts["mime_fixed"]++
		}
		counts["updated"]++

		if *dryRun {
			log.Printf("[dry-run] would update id=%d w=%d h=%d mime=%s->%s path=%q",
				f.ID, cfgImg.Width, cfgImg.Height, f.MimeType, detectedMime, f.Path)
			continue
		}
		if err := db.Model(f).Updates(updates).Error; err != nil {
			log.Printf("[warn] 更新 id=%d 失败: %v", f.ID, err)
			continue
		}
		log.Printf("[update] id=%d w=%d h=%d mime=%s path=%q", f.ID, cfgImg.Width, cfgImg.Height, f.MimeType, f.Path)
	}

	log.Printf("完成: total=%d updated=%d missing_file=%d invalid_path=%d decode_failed=%d mime_fixed=%d dry_run=%v",
		len(files),
		counts["updated"],
		counts["missing_file"],
		counts["invalid_path"],
		counts["decode_failed"],
		counts["mime_fixed"],
		*dryRun,
	)
}

func isSupportedImage(mimeType string) bool {
	switch mimeType {
	case "image/jpeg", "image/png", "image/gif":
		return true
	default:
		return false
	}
}

func openDB(dsn string) *gorm.DB {
	if dsn == "" || dsn == "./shenliyuan.db" {
		if content, err := os.ReadFile("/opt/shenliyuan/.env"); err == nil {
			for _, line := range strings.Split(string(content), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "DSN=") {
					dsn = strings.TrimPrefix(line, "DSN=")
					break
				}
			}
		}
	}
	var db *gorm.DB
	var err error
	if strings.Contains(dsn, "host=") || strings.Contains(dsn, "port=") ||
		strings.Contains(dsn, "postgres") || strings.Contains(dsn, "user=") {
		db, err = gorm.Open(postgres.Open(dsn), &gorm.Config{})
	} else {
		db, err = gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	}
	if err != nil {
		log.Fatalf("连接数据库失败: %v", err)
	}
	return db
}
