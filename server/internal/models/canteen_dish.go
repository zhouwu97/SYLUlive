package models

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gorm.io/gorm"
)

// DishStatus 菜品状态
const (
	DishStatusPending  = "pending"
	DishStatusActive   = "active"
	DishStatusHidden   = "hidden"
	DishStatusRejected = "rejected"
	DishStatusArchived = "archived"
	DishStatusMerged   = "merged"
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
	ID               uint       `gorm:"primaryKey" json:"id"`
	CanteenID        uint       `gorm:"not null;index" json:"canteen_id"`
	Name             string     `gorm:"size:100;not null" json:"name"`
	NormalizedName   string     `gorm:"size:100;not null" json:"-"`
	Status           string     `gorm:"size:20;not null;default:'active';index" json:"status"`
	MergedIntoDishID *uint      `gorm:"index" json:"merged_into_dish_id,omitempty"`
	CreatedBy        uint       `gorm:"not null;index" json:"created_by"`
	RejectReason     string     `gorm:"size:200" json:"reject_reason,omitempty"`
	ReviewedBy       *uint      `json:"reviewed_by,omitempty"`
	ReviewedAt       *time.Time `json:"reviewed_at,omitempty"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
}

// CanteenDishPhoto 菜品实拍（最多 3 张 approved）
type CanteenDishPhoto struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	DishID        uint       `gorm:"not null;index" json:"dish_id"`
	FileID        uint       `gorm:"not null;index" json:"file_id"`
	UserID        uint       `gorm:"not null;index" json:"user_id"`
	Status        string     `gorm:"size:20;not null;default:'approved';index" json:"status"`
	SortOrder     int        `gorm:"not null;default:0" json:"sort_order"`
	ReviewedBy    *uint      `json:"reviewed_by"`
	ReviewedAt    *time.Time `json:"reviewed_at"`
	RejectReason  string     `gorm:"size:200" json:"reject_reason"`
	ReviewEventID *uint      `gorm:"index" json:"review_event_id,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

// EnsureCanteenDishSchema 建立菜品图库的数据库级唯一约束（幂等）。
func EnsureCanteenDishSchema(db *gorm.DB) error {
	statements := []string{
		// 同食堂归一化菜名唯一
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_dish_name
		 ON canteen_dishes (canteen_id, normalized_name)`,
		// 同一文件不能重复进入菜品图库（配合 File.SHA-256 去重 = 免费完全重复检测）
		`CREATE UNIQUE INDEX IF NOT EXISTS uq_canteen_dish_photo_file
		 ON canteen_dish_photos (file_id)`,
		// 历史 pending 索引安全移除
		`DROP INDEX IF EXISTS uq_pending_dish_photo_user`,
	}
	for _, statement := range statements {
		if err := db.Exec(statement).Error; err != nil {
			log.Printf("Error creating canteen dish index: %v", err)
			return err
		}
	}
	return nil
}

func validatePhotoFileOnDisk(f File) bool {
	if !strings.HasPrefix(strings.ToLower(f.MimeType), "image/") {
		return false
	}
	uploadDir := os.Getenv("UPLOAD_DIR")
	if uploadDir == "" {
		uploadDir = "./uploads"
	}
	rel := strings.TrimPrefix(f.Path, "/uploads/")
	rel = strings.TrimPrefix(rel, "uploads/")
	fullPath := filepath.Join(uploadDir, filepath.FromSlash(rel))
	info, err := os.Stat(fullPath)
	return err == nil && !info.IsDir()
}

const CanteenPendingDishMigrationVersion = "20260825_01_canteen_pending_dish_migration"

// MigratePendingDishesAndPhotos 迁移历史 pending 菜品和实拍（一次性迁移）：
// 1. 将所有 status = 'pending' 的 CanteenDish 自动转为 'active'；
// 2. 将合法且文件存在的 pending 实拍转为 'approved' 并将 File 设为 public；
// 3. 历史 rejected / hidden / archived 状态保持不变。
//
// 此迁移只运行一次。运行后不再自动处理新产生的 pending 数据。
func MigratePendingDishesAndPhotos(db *gorm.DB) error {
	if err := db.AutoMigrate(&AppSchemaMigration{}); err != nil {
		return err
	}

	var existing AppSchemaMigration
	if err := db.Where("version = ?", CanteenPendingDishMigrationVersion).First(&existing).Error; err == nil {
		// 已经运行过，跳过
		return nil
	}

	return db.Transaction(func(tx *gorm.DB) error {
		// 1. 将所有 pending 状态的菜品迁移为 active
		if err := tx.Model(&CanteenDish{}).
			Where("status = ?", DishStatusPending).
			Update("status", DishStatusActive).Error; err != nil {
			return err
		}

		// 2. 迁移实拍图片
		var dishIDs []uint
		if err := tx.Model(&CanteenDishPhoto{}).
			Where("status = ?", DishPhotoStatusPending).
			Distinct().
			Pluck("dish_id", &dishIDs).Error; err != nil {
			return err
		}
		if len(dishIDs) == 0 {
			// 记录迁移完成
			return tx.Create(&AppSchemaMigration{
				Version:   CanteenPendingDishMigrationVersion,
				AppliedAt: time.Now().UTC(),
			}).Error
		}

		for _, dishID := range dishIDs {
			var dish CanteenDish
			if err := tx.First(&dish, dishID).Error; err != nil {
				return err
			}
			if dish.Status == DishStatusHidden || dish.Status == DishStatusArchived || dish.Status == DishStatusRejected {
				if err := tx.Model(&CanteenDishPhoto{}).
					Where("dish_id = ? AND status = ?", dishID, DishPhotoStatusPending).
					Update("status", DishPhotoStatusArchived).Error; err != nil {
					return err
				}
				continue
			}
			var approvedCount int64
			if err := tx.Model(&CanteenDishPhoto{}).
				Where("dish_id = ? AND status = ?", dishID, DishPhotoStatusApproved).
				Count(&approvedCount).Error; err != nil {
				return err
			}
			capacity := 3 - int(approvedCount)
			if capacity < 0 {
				capacity = 0
			}

			var pendingPhotos []CanteenDishPhoto
			if err := tx.Where("dish_id = ? AND status = ?", dishID, DishPhotoStatusPending).
				Order("created_at ASC, id ASC").
				Find(&pendingPhotos).Error; err != nil {
				return err
			}

			var toApproveIDs []uint
			var toApproveFileIDs []uint
			var toArchiveIDs []uint

			for _, p := range pendingPhotos {
				if len(toApproveIDs) < capacity {
					var file File
					if err := tx.First(&file, p.FileID).Error; err == nil && validatePhotoFileOnDisk(file) {
						toApproveIDs = append(toApproveIDs, p.ID)
						toApproveFileIDs = append(toApproveFileIDs, p.FileID)
						continue
					}
				}
				toArchiveIDs = append(toArchiveIDs, p.ID)
			}

			if len(toApproveIDs) > 0 {
				if err := tx.Model(&CanteenDishPhoto{}).
					Where("id IN ?", toApproveIDs).
					Update("status", DishPhotoStatusApproved).Error; err != nil {
					return err
				}
				if err := tx.Model(&File{}).
					Where("id IN ?", toApproveFileIDs).
					Updates(map[string]interface{}{
						"status":       "active",
						"access_scope": FileAccessPublic,
					}).Error; err != nil {
					return err
				}
			}
			if len(toArchiveIDs) > 0 {
				if err := tx.Model(&CanteenDishPhoto{}).
					Where("id IN ?", toArchiveIDs).
					Update("status", DishPhotoStatusArchived).Error; err != nil {
					return err
				}
			}
		}

		// 记录迁移完成
		return tx.Create(&AppSchemaMigration{
			Version:   CanteenPendingDishMigrationVersion,
			AppliedAt: time.Now().UTC(),
		}).Error
	})
}

// MigratePendingCanteenDishPhotos 保留历史函数名向后兼容
func MigratePendingCanteenDishPhotos(db *gorm.DB) error {
	return MigratePendingDishesAndPhotos(db)
}
