package models

import "time"

// UserViolation 用户违规记录
type UserViolation struct {
	ID         uint       `gorm:"primaryKey" json:"id"`
	UserID     uint       `gorm:"index;not null" json:"user_id"`
	BoardID    uint       `gorm:"index" json:"board_id"`
	Reason     string     `gorm:"size:500" json:"reason"`
	Action     string     `gorm:"size:50" json:"action"`
	Count      int        `gorm:"default:1" json:"count"`
	Appealed   bool       `gorm:"default:false" json:"appealed"`
	MutedUntil *time.Time `json:"muted_until,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`

	User User `gorm:"foreignKey:UserID" json:"user,omitempty"`
}
