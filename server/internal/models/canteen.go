package models

import "time"

// Canteen 食堂/店铺
type Canteen struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Name      string    `gorm:"size:100;not null;index" json:"name"`
	Image     string    `gorm:"size:500;not null" json:"image"` // 封面图
	Verified  bool      `gorm:"default:true" json:"verified"` // 用户添加直接通过
	CreatedBy uint      `gorm:"index" json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	RatingCount int     `gorm:"-" json:"rating_count"`
	AverageStar float64 `gorm:"-" json:"average_star"`
}

// CanteenRating 食堂评价
type CanteenRating struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	CanteenID uint      `gorm:"index;not null" json:"canteen_id"`
	UserID    uint      `gorm:"index;not null" json:"user_id"`
	Star      int       `gorm:"not null" json:"star"`           // 1-5星
	Comment   string    `gorm:"size:500" json:"comment"`        // 评价文字
	Images    string    `gorm:"type:text" json:"images"`        // 图片JSON数组
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	// 关联数据（非数据库字段）
	UserName      string `gorm:"-" json:"user_name"`
	UserStudentID string `gorm:"-" json:"user_student_id"`
	UserAvatar    string `gorm:"-" json:"user_avatar"`
}
