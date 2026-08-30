// 回填历史标准 WaterTag 为 Topic。默认只做 dry-run，确认报告后再使用 --apply。
//
//	go run ./cmd/backfill_post_topics --dry-run
//	go run ./cmd/backfill_post_topics --apply
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/glebarez/sqlite"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"
	"shenliyuan/internal/services"
)

type backfillPlan struct {
	StandardTags          int
	SpecialTags           int
	TaggedPosts           int
	MatchedStandardRefs   int
	SkippedSpecialRefs    int
	IgnoredLegacyRefs     int
	InvalidRefs           int
	InvalidNameRefs       int
	DuplicateAssociations int
	TopicNames            map[string]string
	Associations          []association
}

type association struct {
	PostID uint
	Name   string
}

// 这些旧 WaterTag 没有稳定语义，不应污染新 Topic 推荐和首页展示。
var ignoredLegacyTopicNames = map[string]struct{}{
	"其他":  {},
	"其它":  {},
	"默认":  {},
	"未分类": {},
	"综合":  {},
}

func main() {
	dryRun := flag.Bool("dry-run", false, "只统计不写入；默认模式")
	apply := flag.Bool("apply", false, "执行回填写入")
	flag.Parse()
	if *dryRun && *apply {
		log.Fatal("--dry-run 与 --apply 不能同时使用")
	}

	db := openDB(config.Load().DSN)
	plan, err := buildPlan(db)
	if err != nil {
		log.Fatalf("生成回填报告失败: %v", err)
	}
	log.Printf("standard WaterTag 数量: %d", plan.StandardTags)
	log.Printf("special WaterTag 数量: %d", plan.SpecialTags)
	log.Printf("历史带 WaterTag 帖子数: %d", plan.TaggedPosts)
	log.Printf("匹配标准 WaterTag 引用数: %d", plan.MatchedStandardRefs)
	log.Printf("跳过特殊 content_mode 引用数: %d", plan.SkippedSpecialRefs)
	log.Printf("跳过无意义 legacy 名称引用数: %d", plan.IgnoredLegacyRefs)
	log.Printf("非法引用数: %d", plan.InvalidRefs)
	log.Printf("无效 Topic 名称数: %d", plan.InvalidNameRefs)
	log.Printf("重复关联合并数: %d", plan.DuplicateAssociations)
	log.Printf("预计 Topic 数量: %d", len(plan.TopicNames))
	log.Printf("预计新增关联数: %d", len(plan.Associations))
	if plan.InvalidRefs > 0 {
		log.Fatal("存在非法 WaterTag 引用，已停止；请先修复数据")
	}
	if !*apply {
		log.Printf("dry-run 完成，未修改数据库")
		return
	}
	if err := applyPlan(db, plan); err != nil {
		log.Fatalf("执行回填失败: %v", err)
	}
	log.Printf("回填完成，原 water_tag_id 未修改")
}

func buildPlan(db *gorm.DB) (backfillPlan, error) {
	plan := backfillPlan{TopicNames: map[string]string{}}
	var standardTags []models.WaterSectionTag
	if err := db.Where("content_mode = ?", models.WaterTagModeStandard).Find(&standardTags).Error; err != nil {
		return plan, err
	}
	plan.StandardTags = len(standardTags)
	var specialTagCount int64
	if err := db.Model(&models.WaterSectionTag{}).
		Where("content_mode <> ?", models.WaterTagModeStandard).Count(&specialTagCount).Error; err != nil {
		return plan, err
	}
	plan.SpecialTags = int(specialTagCount)
	byID := make(map[uint]models.WaterSectionTag, len(standardTags))
	for _, tag := range standardTags {
		byID[tag.ID] = tag
	}

	var posts []models.Post
	if err := db.Where("water_tag_id IS NOT NULL").Find(&posts).Error; err != nil {
		return plan, err
	}
	plan.TaggedPosts = len(posts)
	var existing []struct {
		PostID         uint
		NormalizedName string
	}
	if err := db.Table("post_topics AS pt").
		Select("pt.post_id, topics.normalized_name").
		Joins("JOIN topics ON topics.id = pt.topic_id").
		Find(&existing).Error; err != nil {
		return plan, err
	}
	seen := make(map[string]struct{}, len(existing))
	for _, link := range existing {
		seen[fmt.Sprintf("%d:%s", link.PostID, link.NormalizedName)] = struct{}{}
	}
	for _, post := range posts {
		if post.WaterTagID == nil {
			continue
		}
		tag, ok := byID[*post.WaterTagID]
		if !ok {
			var special models.WaterSectionTag
			if err := db.First(&special, *post.WaterTagID).Error; err != nil {
				plan.InvalidRefs++
			} else {
				plan.SkippedSpecialRefs++
			}
			continue
		}
		plan.MatchedStandardRefs++
		name, err := services.NormalizeTopicName(tag.Name)
		if err != nil {
			plan.InvalidNameRefs++
			continue
		}
		if _, ignored := ignoredLegacyTopicNames[name]; ignored {
			plan.IgnoredLegacyRefs++
			continue
		}
		plan.TopicNames[name] = name
		// Topic ID 在 dry-run 期间未知，先把业务上的唯一关联去重。
		key := fmt.Sprintf("%d:%s", post.ID, name)
		if _, ok := seen[key]; ok {
			plan.DuplicateAssociations++
			continue
		}
		seen[key] = struct{}{}
		plan.Associations = append(plan.Associations, association{PostID: post.ID, Name: name})
	}
	return plan, nil
}

func applyPlan(db *gorm.DB, plan backfillPlan) error {
	return db.Transaction(func(tx *gorm.DB) error {
		for _, item := range plan.Associations {
			var topic models.Topic
			if err := tx.Where("normalized_name = ?", item.Name).First(&topic).Error; err != nil {
				if err != gorm.ErrRecordNotFound {
					return err
				}
				topic = models.Topic{Name: item.Name, NormalizedName: item.Name, Status: models.TopicStatusActive}
				if err := tx.Clauses(clause.OnConflict{
					Columns:   []clause.Column{{Name: "normalized_name"}},
					DoNothing: true,
				}).Create(&topic).Error; err != nil {
					return err
				}
				if err := tx.Where("normalized_name = ?", item.Name).First(&topic).Error; err != nil {
					return err
				}
			}
			if topic.Status != models.TopicStatusActive {
				return fmt.Errorf("topic %q is not active", item.Name)
			}
			if err := tx.Clauses(clause.OnConflict{DoNothing: true}).Create(&models.PostTopic{
				PostID: item.PostID, TopicID: topic.ID, SortOrder: 0,
			}).Error; err != nil {
				return err
			}
		}
		return tx.Exec(`UPDATE topics t SET usage_count = (
            SELECT COUNT(*) FROM post_topics pt WHERE pt.topic_id = t.id
        )`).Error
	})
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
	if strings.Contains(dsn, "host=") || strings.Contains(dsn, "port=") || strings.Contains(dsn, "postgres") || strings.Contains(dsn, "user=") {
		db, err = gorm.Open(postgres.Open(dsn), &gorm.Config{})
	} else {
		db, err = gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	}
	if err != nil {
		log.Fatalf("连接数据库失败: %v", err)
	}
	return db
}
