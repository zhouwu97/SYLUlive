package models

import "time"

// Teacher 避雷板块教师信息
type Teacher struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	Name         string    `gorm:"size:100;not null;uniqueIndex" json:"name"`
	Department   string    `gorm:"size:200" json:"department"`
	PositiveCount int     `gorm:"default:0" json:"positive_count"` // 好评数
	NegativeCount int     `gorm:"default:0" json:"negative_count"` // 差评数
	CreatedBy    uint      `gorm:"not null" json:"created_by"`
	Verified     bool      `gorm:"default:false" json:"verified"` // 管理员验证
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// TeacherRating 教师评分记录
type TeacherRating struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	TeacherID uint      `gorm:"not null;index" json:"teacher_id"`
	UserID    uint      `gorm:"not null" json:"user_id"`
	Rating    string    `gorm:"size:10;not null" json:"rating"` // "positive" or "negative"
	Comment   string    `gorm:"type:text" json:"comment"`
	CreatedAt time.Time `json:"created_at"`
}

// UserViolation 用户违规记录
type UserViolation struct {
	ID         uint       `gorm:"primaryKey" json:"id"`
	UserID     uint       `gorm:"not null;index" json:"user_id"`
	BoardID    uint       `gorm:"not null" json:"board_id"`
	Reason     string     `gorm:"size:500;not null" json:"reason"`
	Action     string     `gorm:"size:50;not null" json:"action"` // "delete_post", "delete_reply"
	Count      int        `gorm:"not null" json:"count"`          // 第几次违规
	MutedUntil *time.Time `json:"muted_until"`                    // 禁言截止
	Appealed   bool       `gorm:"default:false" json:"appealed"`
	CreatedAt  time.Time  `json:"created_at"`
	User       User       `gorm:"foreignKey:UserID" json:"user"`
}
