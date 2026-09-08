package models

import "time"

// AccountLoginAlias 固定历史登录名，与可变的教务配置和认证记录分离。
// 同号历史冲突保留事实，由登录查询拒绝歧义，不能任意挑选账号。
type AccountLoginAlias struct {
	ID        uint   `gorm:"primaryKey"`
	UserID    uint   `gorm:"not null;uniqueIndex:ux_login_alias_user_value,priority:1"`
	Value     string `gorm:"size:128;not null;index;uniqueIndex:ux_login_alias_user_value,priority:2"`
	Source    string `gorm:"size:64;not null"`
	CreatedAt time.Time
}
