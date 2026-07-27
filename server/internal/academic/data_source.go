// Package academic 定义校园 Agent 读取学业上下文时使用的通用契约。
package academic

// DataSource 标识上下文的实际来源，不表达模型推断或底层访问方式。
type DataSource string

const (
	DataSourceServerSnapshot       DataSource = "server_snapshot"
	DataSourceDeviceEncryptedCache DataSource = "device_encrypted_cache"
	DataSourceRemoteEduFetch       DataSource = "remote_edu_fetch"
	DataSourceUserUploadedSnapshot DataSource = "user_uploaded_snapshot"
	DataSourcePublicDatabase       DataSource = "public_database"
	DataSourceKnowledgeBase        DataSource = "knowledge_base"
	DataSourceNone                 DataSource = "none"
)

// Valid 判断来源是否属于允许对外暴露的语义来源。
func (source DataSource) Valid() bool {
	switch source {
	case DataSourceServerSnapshot,
		DataSourceDeviceEncryptedCache,
		DataSourceRemoteEduFetch,
		DataSourceUserUploadedSnapshot,
		DataSourcePublicDatabase,
		DataSourceKnowledgeBase,
		DataSourceNone:
		return true
	default:
		return false
	}
}

// DataStatus 标识数据当前可用性；过期数据仍可读取，但必须显式标记为 stale。
type DataStatus string

const (
	DataStatusAvailable          DataStatus = "available"
	DataStatusStale              DataStatus = "stale"
	DataStatusMissing            DataStatus = "missing"
	DataStatusNeedsRefresh       DataStatus = "needs_refresh"
	DataStatusCorrupted          DataStatus = "corrupted"
	DataStatusPartial            DataStatus = "partial"
	DataStatusPermissionRequired DataStatus = "permission_required"
	DataStatusDeviceOffline      DataStatus = "device_offline"
	DataStatusFetching           DataStatus = "fetching"
	DataStatusFailed             DataStatus = "failed"
)

// Valid 判断状态是否属于跨端共享的数据状态。
func (status DataStatus) Valid() bool {
	switch status {
	case DataStatusAvailable,
		DataStatusStale,
		DataStatusMissing,
		DataStatusNeedsRefresh,
		DataStatusCorrupted,
		DataStatusPartial,
		DataStatusPermissionRequired,
		DataStatusDeviceOffline,
		DataStatusFetching,
		DataStatusFailed:
		return true
	default:
		return false
	}
}
