package main

import (
	"log"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
)

func main() {
	// load env relative to cmd
	cfg := config.Load()

	dsn := cfg.DSN

	log.Println("connecting to", dsn)
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	if err != nil {
		log.Fatal(err)
	}

	var compID uint
	if err := db.Model(&models.WaterSection{}).Where("slug = ?", "competition").Select("id").Scan(&compID).Error; err == nil && compID > 0 {
		db.Exec("UPDATE water_section_tags SET is_enabled = 0 WHERE section_id = ? AND slug IN ('algorithm', 'modeling')", compID)
		log.Println("updated competition tags")
	}

	var lifeID uint
	if err := db.Model(&models.WaterSection{}).Where("slug = ?", "campus_life").Select("id").Scan(&lifeID).Error; err == nil && lifeID > 0 {
		db.Exec("UPDATE water_section_tags SET is_enabled = 0 WHERE section_id = ? AND slug IN ('campus_card', 'snapshot')", lifeID)
		
		tags := []struct{Slug string; Name string; Order int}{
			{"daily", "日常", 10},
			{"dormitory", "宿舍", 20},
			{"canteen", "食堂", 30},
			{"campus_view", "校园见闻", 40},
			{"other", "其他", 50},
		}

		for _, t := range tags {
			var existing int64
			db.Model(&models.WaterSectionTag{}).Where("section_id = ? AND slug = ?", lifeID, t.Slug).Count(&existing)
			if existing > 0 {
				db.Exec("UPDATE water_section_tags SET is_enabled = 1, sort_order = ?, name = ? WHERE section_id = ? AND slug = ?", t.Order, t.Name, lifeID, t.Slug)
			} else {
				db.Exec("INSERT INTO water_section_tags (section_id, slug, name, description, sort_order, is_default, is_enabled) VALUES (?, ?, ?, '', ?, 1, 1)", lifeID, t.Slug, t.Name, t.Order)
			}
		}
		log.Println("updated campus_life tags")
	}

	log.Println("done")
}
