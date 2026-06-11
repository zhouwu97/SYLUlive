package models

import "time"

// Major 专业
type Major struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Name      string    `gorm:"size:100;not null;index" json:"name"`
	Level     string    `gorm:"size:20;not null" json:"level"` // 本科/研究生
	Verified  bool      `gorm:"default:false" json:"verified"`
	CreatedBy uint      `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	RatingCount int     `gorm:"-" json:"rating_count"`
	AverageStar float64 `gorm:"-" json:"average_star"`
}

// MajorRating 专业评价
type MajorRating struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	MajorID   uint      `gorm:"index;not null" json:"major_id"`
	UserID    uint      `gorm:"index;not null" json:"user_id"`
	Star      int       `gorm:"not null" json:"star"`
	Comment   string    `gorm:"size:500" json:"comment"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	User          *User  `gorm:"foreignKey:UserID" json:"-"`
	UserName      string `gorm:"-" json:"user_name"`
	UserStudentID string `gorm:"-" json:"user_student_id"`
}
