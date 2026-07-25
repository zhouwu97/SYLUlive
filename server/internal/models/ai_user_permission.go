package models

import "time"

// AIUserPermissionScope 是校园 Agent 访问个人数据时可配置的持久化权限范围。
// 范围名称稳定对外，不能复用为模型工具或底层数据访问权限。
type AIUserPermissionScope string

const (
	AIUserPermissionPersonalDataAccess   AIUserPermissionScope = "ai_personal_data_access"
	AIUserPermissionDeviceCacheAccess    AIUserPermissionScope = "ai_device_cache_access"
	AIUserPermissionRemoteEduRefresh     AIUserPermissionScope = "ai_remote_edu_refresh"
	AIUserPermissionErkeSnapshotUpload   AIUserPermissionScope = "erke_snapshot_upload"
	AIUserPermissionAcademicCloudStorage AIUserPermissionScope = "academic_cloud_storage"
)

// AIUserPermissionPolicy 只持久化跨会话策略。
// 单次与本会话许可属于交互态，不能被误写成长期授权。
type AIUserPermissionPolicy string

const (
	AIUserPermissionAsk    AIUserPermissionPolicy = "ask"
	AIUserPermissionAlways AIUserPermissionPolicy = "always"
	AIUserPermissionNever  AIUserPermissionPolicy = "never"
)

// AIUserPermission 保存用户对校园 Agent 个人数据访问的长期选择。
// 不保存任何成绩、课表、设备标识或教务凭据。
type AIUserPermission struct {
	ID        uint                   `gorm:"primaryKey" json:"id"`
	UserID    uint                   `gorm:"not null;uniqueIndex:idx_ai_user_permissions_user_scope,priority:1;index" json:"-"`
	Scope     AIUserPermissionScope  `gorm:"size:48;not null;uniqueIndex:idx_ai_user_permissions_user_scope,priority:2;index" json:"scope"`
	Policy    AIUserPermissionPolicy `gorm:"size:16;not null;default:ask" json:"policy"`
	CreatedAt time.Time              `json:"created_at"`
	UpdatedAt time.Time              `json:"updated_at"`
}

func (AIUserPermission) TableName() string { return "ai_user_permissions" }
