package main

import (
	"log"

	"shenliyuan/internal/config"
	"shenliyuan/internal/models"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func main() {
	cfg := config.Load()
	db, err := gorm.Open(sqlite.Open(cfg.DSN), &gorm.Config{})
	if err != nil {
		log.Fatalf("failed to connect database: %v", err)
	}

	// 获取所有水帖版块
	var sections []models.WaterSection
	if err := db.Find(&sections).Error; err != nil {
		log.Fatalf("failed to fetch sections: %v", err)
	}

	for _, section := range sections {
		// 为每个版块生成一些有趣的自定义称号
		titles := []models.WaterSectionLevelTitle{
			{SectionID: section.ID, Level: 1, Title: "小水怪"},
			{SectionID: section.ID, Level: 2, Title: "划水健将"},
			{SectionID: section.ID, Level: 3, Title: "东海龙王"},
			{SectionID: section.ID, Level: 4, Title: "水神降临"},
			{SectionID: section.ID, Level: 5, Title: "汪洋霸主"},
		}

		for _, t := range titles {
			if err := db.Where(models.WaterSectionLevelTitle{SectionID: t.SectionID, Level: t.Level}).
				FirstOrCreate(&t).Error; err != nil {
				log.Printf("failed to insert title %v: %v", t, err)
			}
		}
		log.Printf("Seeded titles for section: %s", section.Title)
	}
	log.Println("Done seeding water section level titles.")
}
