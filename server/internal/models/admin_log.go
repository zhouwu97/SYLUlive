package models

import "time"

// AdminLog 管理员操作日志
type AdminLog struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	AdminID   uint      `gorm:"index;not null" json:"admin_id"`
	AdminName string    `gorm:"size:100" json:"admin_name"`
	Action    string    `gorm:"size:200;not null" json:"action"`
	Target    string    `gorm:"size:200" json:"target"`
	Detail    string    `gorm:"size:500" json:"detail"`
	CreatedAt time.Time `json:"created_at"`

	Admin User `gorm:"foreignKey:AdminID" json:"admin,omitempty"`
}
