package models

import "time"

type WaterSectionFollow struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_user_section_follow" json:"user_id"`
	SectionID uint      `gorm:"not null;uniqueIndex:idx_user_section_follow" json:"section_id"`
	CreatedAt time.Time `json:"created_at"`

	User    *User         `gorm:"foreignKey:UserID" json:"user,omitempty"`
	Section *WaterSection `gorm:"foreignKey:SectionID" json:"section,omitempty"`
}
