package models

import (
	"log"
	"time"

	"gorm.io/gorm"
)

// CanteenRatingDishRecommendation 食堂评价菜品推荐关联
//
// 以用户输入的菜名 (DishName) 为主键字段，NormalizedName 用于聚合统计。
// DishID 是可选的弱引用，仅当菜名匹配到已有 CanteenDish 时填充，不做外键约束。
type CanteenRatingDishRecommendation struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	RatingID       uint      `gorm:"not null;index" json:"rating_id"`
	DishName       string    `gorm:"size:60;not null" json:"dish_name"`
	NormalizedName string    `gorm:"size:60;not null" json:"normalized_name"`
	DishID         *uint     `gorm:"index" json:"dish_id,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
}

// EnsureCanteenRatingRecommendationSchema 建立评价菜品推荐的数据库级约束与索引（幂等）。
func EnsureCanteenRatingRecommendationSchema(db *gorm.DB) error {
	statements := []string{
		// 旧索引清理（幂等；SQLite 使用 IF EXISTS）
		`DROP INDEX IF EXISTS uq_canteen_rating_dish`,
		// 同一评价中同一标准化菜名最多推荐一次
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_rating_dish_name
		 ON canteen_rating_dish_recommendations (rating_id, normalized_name)`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			log.Printf("Error creating canteen rating dish recommendation index: %v", err)
			return err
		}
	}
	return nil
}
