package models

import "time"

// Teacher 被评价教师
type Teacher struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	Name      string    `gorm:"size:50;not null;index" json:"name"`
	Course    string    `gorm:"size:100;not null" json:"course"`
	Verified  bool      `gorm:"default:false" json:"verified"`
	CreatedBy uint      `gorm:"index" json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	RatingCount int     `gorm:"-" json:"rating_count"`
	AverageStar float64 `gorm:"-" json:"average_star"`
}

// TeacherRating 教师评价
type TeacherRating struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	TeacherID uint      `gorm:"index;not null" json:"teacher_id"`
	UserID    uint      `gorm:"index;not null" json:"user_id"`
	Star      int       `gorm:"not null" json:"star"`                    // 1-5星
	Comment   string    `gorm:"size:500" json:"comment"`                  // 评价内容
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`

	// 关联数据（非数据库字段）
	UserName      string `gorm:"-" json:"user_name"`
	UserStudentID string `gorm:"-" json:"user_student_id"`
}
