// 一次性重建 total_likes_received 语义：
// 从 post like + reply like 全量重建 users.total_likes_received，
// 覆盖历史 reply likes（增量维护由 LikeReply/UnlikeReply 负责）。
//
// 用法：go run ./cmd/backfill_total_likes_received
package main

import (
	"log"
	"os"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
)

func main() {
	cfg := config.Load()
	var db *gorm.DB
	var err error

	if cfg.DSN == "./shenliyuan.db" || cfg.DSN == "" {
		content, readErr := os.ReadFile("/opt/shenliyuan/.env")
		if readErr == nil {
			for _, line := range strings.Split(string(content), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "DSN=") {
					cfg.DSN = strings.TrimPrefix(line, "DSN=")
					break
				}
			}
		}
	}

	if strings.Contains(cfg.DSN, "host=") || strings.Contains(cfg.DSN, "port=") ||
		strings.Contains(cfg.DSN, "postgres") || strings.Contains(cfg.DSN, "user=") {
		db, err = gorm.Open(postgres.Open(cfg.DSN), &gorm.Config{})
	} else {
		db, err = gorm.Open(sqlite.Open(cfg.DSN), &gorm.Config{})
	}
	if err != nil {
		log.Fatalf("连接数据库失败: %v", err)
	}

	// 1. 每个作者收到的 post like 数。
	type authorCount struct {
		AuthorID uint
		Count    int
	}
	var postLikes []authorCount
	if err := db.Model(&models.Like{}).
		Select("p.author_id AS author_id, COUNT(*) AS count").
		Joins("JOIN posts p ON p.id = likes.target_id").
		Where("likes.target_type = ?", "post").
		Group("p.author_id").
		Scan(&postLikes).Error; err != nil {
		log.Fatalf("统计 post likes 失败: %v", err)
	}

	// 2. 每个作者收到的 reply like 数。
	var replyLikes []authorCount
	if err := db.Model(&models.Like{}).
		Select("r.author_id AS author_id, COUNT(*) AS count").
		Joins("JOIN replies r ON r.id = likes.target_id").
		Where("likes.target_type = ?", "reply").
		Group("r.author_id").
		Scan(&replyLikes).Error; err != nil {
		log.Fatalf("统计 reply likes 失败: %v", err)
	}

	totals := map[uint]int{}
	for _, row := range postLikes {
		totals[row.AuthorID] += row.Count
	}
	for _, row := range replyLikes {
		totals[row.AuthorID] += row.Count
	}

	// 3. 逐用户写入（rebuild 是幂等覆盖）。
	updated := 0
	for authorID, total := range totals {
		if err := db.Model(&models.User{}).
			Where("id = ?", authorID).
			Update("total_likes_received", total).Error; err != nil {
			log.Printf("[WARN] 更新用户 %d 失败: %v", authorID, err)
			continue
		}
		updated++
	}
	log.Printf("完成：共更新 %d 个用户（post likes=%d 行, reply likes=%d 行）",
		updated, len(postLikes), len(replyLikes))
}
