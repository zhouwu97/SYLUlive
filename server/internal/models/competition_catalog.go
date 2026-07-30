package models

import (
	"time"

	"gorm.io/datatypes"
)

// CompetitionCatalogPackage 保存一次经过服务端校验的目录包及其暂存输入。
type CompetitionCatalogPackage struct {
	ID                    uint           `gorm:"primaryKey" json:"id"`
	SchemaVersion         string         `gorm:"size:80;not null" json:"schema_version"`
	DatasetVersion        string         `gorm:"size:100;not null;uniqueIndex" json:"dataset_version"`
	PackageHash           string         `gorm:"size:64;not null;uniqueIndex" json:"package_hash"`
	PublishStatus         string         `gorm:"size:20;not null;index" json:"publish_status"`
	ProductionLoadAllowed bool           `gorm:"not null;default:false;index" json:"production_load_allowed"`
	ItemCount             int            `gorm:"not null" json:"item_count"`
	ValidationStatus      string         `gorm:"size:20;not null;index" json:"validation_status"`
	ValidationResult      datatypes.JSON `gorm:"not null" json:"validation_result"`
	Payload               datatypes.JSON `gorm:"not null" json:"-"`
	SourceFilename        string         `gorm:"size:255" json:"source_filename"`
	ImportedBy            uint           `gorm:"not null;index" json:"imported_by"`
	ImportedAt            time.Time      `gorm:"not null" json:"imported_at"`
	ActivatedAt           *time.Time     `json:"activated_at,omitempty"`
	IsActive              bool           `gorm:"not null;default:false;index" json:"is_active"`
	PreviousPackageID     *uint          `gorm:"index" json:"previous_package_id,omitempty"`
	CreatedAt             time.Time      `json:"created_at"`
}

func (CompetitionCatalogPackage) TableName() string { return "competition_catalog_packages" }

// CompetitionCatalogAuditLog 只记录目录操作摘要，不保存完整目录或用户画像。
type CompetitionCatalogAuditLog struct {
	ID          uint      `gorm:"primaryKey" json:"id"`
	PackageID   *uint     `gorm:"index" json:"package_id,omitempty"`
	ActorUserID uint      `gorm:"not null;index" json:"actor_user_id"`
	Action      string    `gorm:"size:40;not null;index" json:"action"`
	Result      string    `gorm:"size:20;not null" json:"result"`
	Detail      string    `gorm:"size:500" json:"detail,omitempty"`
	CreatedAt   time.Time `gorm:"index" json:"created_at"`
}

func (CompetitionCatalogAuditLog) TableName() string { return "competition_catalog_audit_logs" }
