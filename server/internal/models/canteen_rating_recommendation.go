package models

import (
	"log"
	"time"

	"gorm.io/gorm"
)

// CanteenRatingDishRecommendation 食堂评价菜品推荐关联
type CanteenRatingDishRecommendation struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	RatingID  uint      `gorm:"not null;index" json:"rating_id"`
	DishID    uint      `gorm:"not null;index" json:"dish_id"`
	CreatedAt time.Time `json:"created_at"`
}

// EnsureCanteenRatingRecommendationSchema 建立评价菜品推荐的数据库级约束与索引（幂等）。
func EnsureCanteenRatingRecommendationSchema(db *gorm.DB) error {
	statements := []string{
		// 同一评价对同一菜品最多推荐一次
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_rating_dish
		 ON canteen_rating_dish_recommendations (rating_id, dish_id)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			log.Printf("Error creating canteen rating dish recommendation index: %v", err)
			return err
		}
	}
	return nil
}
