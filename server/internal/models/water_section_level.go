package models

import "time"

// WaterSectionExpRule 枚举：版块经验发放 action
const (
	WaterSectionExpActionPostDaily  = "post_daily"
	WaterSectionExpActionReplyDaily = "reply_daily"
)

// WaterSectionUserStat 用户在某个水帖版块内的等级统计。
// 每个 (user_id, section_id) 唯一一条；exp 仅在本版块内有效。
type WaterSectionUserStat struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	UserID       uint      `gorm:"not null;uniqueIndex:idx_water_section_stat_user_section" json:"user_id"`
	SectionID    uint      `gorm:"not null;index;uniqueIndex:idx_water_section_stat_user_section" json:"section_id"`
	Exp          int       `gorm:"not null;default:0" json:"exp"`
	PostCount    int       `gorm:"not null;default:0" json:"post_count"`
	ReplyCount   int       `gorm:"not null;default:0" json:"reply_count"`
	LastActiveAt time.Time `json:"last_active_at"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

func (WaterSectionUserStat) TableName() string { return "water_section_user_stats" }

// WaterSectionExpLog 版块经验发放日志，通过 (user_id, section_id, action, date) 唯一约束防止同日重复。
type WaterSectionExpLog struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_water_section_exp_user_section_action_date" json:"user_id"`
	SectionID uint      `gorm:"not null;index;uniqueIndex:idx_water_section_exp_user_section_action_date" json:"section_id"`
	Action    string    `gorm:"size:50;not null;uniqueIndex:idx_water_section_exp_user_section_action_date" json:"action"`
	Date      time.Time `gorm:"type:date;not null;uniqueIndex:idx_water_section_exp_user_section_action_date" json:"date"`
	ExpEarned int       `json:"exp_earned"`
	RefType   string    `gorm:"size:80" json:"ref_type"`
	RefID     uint      `gorm:"index" json:"ref_id"`
	CreatedAt time.Time `json:"created_at"`
}

func (WaterSectionExpLog) TableName() string { return "water_section_exp_logs" }

// WaterSectionLevelTitle 版块等级自定义称号，每个 (section_id, level) 唯一一条。
// 没有记录时使用 defaultWaterSectionLevelTitle(level)。
type WaterSectionLevelTitle struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	SectionID uint      `gorm:"not null;index;uniqueIndex:idx_water_section_title_section_level" json:"section_id"`
	Level     int       `gorm:"not null;uniqueIndex:idx_water_section_title_section_level" json:"level"`
	Title     string    `gorm:"size:32;not null" json:"title"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (WaterSectionLevelTitle) TableName() string { return "water_section_level_titles" }