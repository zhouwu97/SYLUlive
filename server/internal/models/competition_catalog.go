package models

import (
	"time"

	"gorm.io/datatypes"
)

// CompetitionCatalogPackage 保存一次经过服务端校验的目录包及其暂存输入。
type CompetitionCatalogPackage struct {
	ID                    uint           `gorm:"primaryKey" json:"id"`
	SchemaVersion         string         `gorm:"size:80;not null" json:"schema_version"`
	DatasetVersion        string         `gorm:"size:100;not null;index;uniqueIndex:idx_competition_catalog_dataset_revision,priority:1" json:"dataset_version"`
	Revision              int            `gorm:"not null;uniqueIndex:idx_competition_catalog_dataset_revision,priority:2" json:"revision"`
	PackageHash           string         `gorm:"size:64;not null;uniqueIndex" json:"package_hash"`
	LifecycleStatus       string         `gorm:"size:20;not null;default:'staged';index" json:"lifecycle_status"`
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

// CompetitionCatalogLegacyMapping 记录目录赛事与旧赛事之间经过审核的稳定映射。
// 激活器只允许 confirmed 映射复用旧事件 ID，避免模糊匹配覆盖生产关联。
type CompetitionCatalogLegacyMapping struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	PackageID     uint       `gorm:"not null;index;uniqueIndex:idx_catalog_legacy_mapping,priority:1" json:"package_id"`
	CompetitionID string     `gorm:"size:64;not null;index;uniqueIndex:idx_catalog_legacy_mapping,priority:2" json:"competition_id"`
	LegacyEventID uint       `gorm:"not null;index" json:"legacy_event_id"`
	MatchType     string     `gorm:"size:32;not null;index" json:"match_type"`
	Confidence    float64    `gorm:"not null;default:0" json:"confidence"`
	ReviewStatus  string     `gorm:"size:20;not null;default:'suggested';index" json:"review_status"`
	ReviewedBy    *uint      `gorm:"index" json:"reviewed_by,omitempty"`
	ReviewedAt    *time.Time `json:"reviewed_at,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

func (CompetitionCatalogLegacyMapping) TableName() string {
	return "competition_catalog_legacy_mappings"
}

// CompetitionLegacyDuplicateResolution 逐条记录旧赛事副本归并关系，供审计和恢复使用。
type CompetitionLegacyDuplicateResolution struct {
	ID                      uint      `gorm:"primaryKey" json:"id"`
	IdentityHash            string    `gorm:"size:64;not null;index" json:"identity_hash"`
	CanonicalEventID        uint      `gorm:"not null;index" json:"canonical_event_id"`
	DuplicateEventID        uint      `gorm:"not null;uniqueIndex" json:"duplicate_event_id"`
	Reason                  string    `gorm:"size:100;not null" json:"reason"`
	DuplicatePreviousStatus string    `gorm:"size:20;not null" json:"duplicate_previous_status"`
	DuplicateWasDeleted     bool      `gorm:"not null" json:"duplicate_was_deleted"`
	CanonicalWasDeleted     bool      `gorm:"not null" json:"canonical_was_deleted"`
	ResolvedBy              uint      `gorm:"not null;index" json:"resolved_by"`
	ResolvedAt              time.Time `gorm:"not null;index" json:"resolved_at"`
}

func (CompetitionLegacyDuplicateResolution) TableName() string {
	return "competition_legacy_duplicate_resolutions"
}

// CompetitionCatalogActivationSnapshot 保存一次短期激活预检的不可变输入摘要。
// 原始 token 不落库，激活成功后同一快照不可重复使用。
type CompetitionCatalogActivationSnapshot struct {
	ID                      uint           `gorm:"primaryKey" json:"id"`
	PackageID               uint           `gorm:"not null;index" json:"package_id"`
	PackageHash             string         `gorm:"size:64;not null;index" json:"package_hash"`
	ExpectedActivePackageID *uint          `gorm:"index" json:"expected_active_package_id,omitempty"`
	TokenHash               string         `gorm:"size:64;not null;uniqueIndex" json:"-"`
	Report                  datatypes.JSON `gorm:"not null" json:"report"`
	Status                  string         `gorm:"size:20;not null;default:'ready';index" json:"status"`
	CreatedBy               uint           `gorm:"not null;index" json:"created_by"`
	CreatedAt               time.Time      `gorm:"not null;index" json:"created_at"`
	ExpiresAt               time.Time      `gorm:"not null;index" json:"expires_at"`
	ConsumedAt              *time.Time     `json:"consumed_at,omitempty"`
}

func (CompetitionCatalogActivationSnapshot) TableName() string {
	return "competition_catalog_activation_snapshots"
}
