package models

import "time"

const (
	OneClassUpdateScopeAll          = "all"
	OneClassUpdateScopeLifetimePlus = "lifetime_plus"
	OneClassUpdateScopeLifetimeOnly = "lifetime_updates"
	OneClassUpdateScopeUpgradeOnly  = "upgrade_updates"
)

// OneClassUpdate 用于向 OneClass 授权用户发布更新通知。
type OneClassUpdate struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	Title       string    `gorm:"size:200;not null" json:"title"`
	Content     string    `gorm:"type:text;not null" json:"content"`
	Version     string    `gorm:"size:64" json:"version"`
	DownloadURL string    `gorm:"size:500" json:"download_url"`
	TargetScope string    `gorm:"size:32;default:'lifetime_plus';index" json:"target_scope"`
	ForceUpdate bool      `gorm:"default:false" json:"force_update"`
	IsActive    bool      `gorm:"default:true;index" json:"is_active"`
	CreatedBy   uint      `gorm:"not null" json:"created_by"`
	Creator     User      `gorm:"foreignKey:CreatedBy" json:"creator"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

func (OneClassUpdate) TableName() string {
	return "oneclass_updates"
}
