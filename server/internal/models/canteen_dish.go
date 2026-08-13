package models

import (
	"log"
	"time"

	"gorm.io/gorm"
)

// DishStatus 菜品状态
const (
	DishStatusActive = "active"
	DishStatusHidden = "hidden"
)

// DishPhotoStatus 菜品实拍状态
const (
	DishPhotoStatusPending  = "pending"
	DishPhotoStatusApproved = "approved"
	DishPhotoStatusRejected = "rejected"
	DishPhotoStatusArchived = "archived"
)

// CanteenDish 食堂菜品
type CanteenDish struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	CanteenID      uint      `gorm:"not null;index" json:"canteen_id"`
	Name           string    `gorm:"size:100;not null" json:"name"`
	NormalizedName string    `gorm:"size:100;not null" json:"-"`
	Status         string    `gorm:"size:20;not null;default:'active';index" json:"status"`
	CreatedBy      uint      `gorm:"not null;index" json:"created_by"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// CanteenDishPhoto 菜品实拍（最多 3 张 approved）
type CanteenDishPhoto struct {
	ID           uint       `gorm:"primaryKey" json:"id"`
	DishID       uint       `gorm:"not null;index" json:"dish_id"`
	FileID       uint       `gorm:"not null;index" json:"file_id"`
	UserID       uint       `gorm:"not null;index" json:"user_id"`
	Status       string     `gorm:"size:20;not null;default:'pending';index" json:"status"`
	SortOrder    int        `gorm:"not null;default:0" json:"sort_order"`
	ReviewedBy   *uint      `json:"reviewed_by"`
	ReviewedAt   *time.Time `json:"reviewed_at"`
	RejectReason string     `gorm:"size:200" json:"reject_reason"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`
}

// EnsureCanteenDishSchema 建立菜品图库的数据库级唯一约束（幂等）。
// SQLite (modernc.org/sqlite) 与 PostgreSQL 均支持 partial unique index。
func EnsureCanteenDishSchema(db *gorm.DB) error {
	statements := []string{
		// 同食堂归一化菜名唯一
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_dish_name
		 ON canteen_dishes (canteen_id, normalized_name)`,
		// 同一文件不能重复进入菜品图库（配合 File.SHA-256 去重 = 免费完全重复检测）
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_dish_photo_file
		 ON canteen_dish_photos (file_id)`,
		// 同一用户同一道菜最多一个 pending
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_pending_dish_photo_user
		 ON canteen_dish_photos (dish_id, user_id)
		 WHERE status = 'pending'`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			log.Printf("Error creating canteen dish index: %v", err)
			return err
		}
	}
	return nil
}
