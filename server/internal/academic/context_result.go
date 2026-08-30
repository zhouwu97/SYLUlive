package academic

import (
	"encoding/json"
	"fmt"
	"time"
)

// Evidence 说明结果实际使用的数据来源，供 Agent 审计与客户端证据区展示。
type Evidence struct {
	Source    DataSource  `json:"source"`
	Dataset   DatasetType `json:"dataset"`
	ScopeKey  string      `json:"scope_key,omitempty"`
	FetchedAt *time.Time  `json:"fetched_at,omitempty"`
	ExpiresAt *time.Time  `json:"expires_at,omitempty"`
	IsStale   bool        `json:"is_stale"`
}

// ContextResult 是所有校园 Agent 个人数据工具的结果信封。
// Data 只保存裁剪后的业务结果，不得放入凭据、Cookie 或原始页面内容。
type ContextResult struct {
	Data      json.RawMessage `json:"data"`
	Status    DataStatus      `json:"status"`
	Source    DataSource      `json:"source"`
	ErrorCode string          `json:"error_code,omitempty"`
	FetchedAt *time.Time      `json:"fetched_at,omitempty"`
	ExpiresAt *time.Time      `json:"expires_at,omitempty"`
	IsStale   bool            `json:"is_stale"`
	IsPartial bool            `json:"is_partial"`
	Warnings  []string        `json:"warnings"`
	Evidence  []Evidence      `json:"evidence"`
}

// SnapshotLookup 允许上层来源解析器区分不存在、载荷损坏和可使用的快照。
// 它位于 academic 包，避免 Agent 工具层依赖具体的持久化服务实现。
type SnapshotLookup struct {
	Found     bool
	Corrupted bool
	Result    ContextResult
}

// NewContextResult 创建字段齐全的结果信封，确保 data、warnings 和 evidence 不会序列化为 null。
func NewContextResult(data any, status DataStatus, source DataSource) (ContextResult, error) {
	if !status.Valid() {
		return ContextResult{}, fmt.Errorf("unsupported data status: %s", status)
	}
	if !source.Valid() {
		return ContextResult{}, fmt.Errorf("unsupported data source: %s", source)
	}
	payload, err := json.Marshal(data)
	if err != nil {
		return ContextResult{}, fmt.Errorf("marshal context data: %w", err)
	}
	return ContextResult{
		Data:     payload,
		Status:   status,
		Source:   source,
		Warnings: make([]string, 0),
		Evidence: make([]Evidence, 0),
	}, nil
}

// Validate 校验工具结果在写入审计日志或传给模型前保持可解释的来源与状态。
func (result ContextResult) Validate() error {
	if !result.Status.Valid() {
		return fmt.Errorf("unsupported data status: %s", result.Status)
	}
	if !result.Source.Valid() {
		return fmt.Errorf("unsupported data source: %s", result.Source)
	}
	if len(result.Data) == 0 || !json.Valid(result.Data) {
		return fmt.Errorf("context data must be valid JSON")
	}
	for _, evidence := range result.Evidence {
		if !evidence.Source.Valid() {
			return fmt.Errorf("unsupported evidence source: %s", evidence.Source)
		}
		if !evidence.Dataset.Valid() {
			return fmt.Errorf("unsupported evidence dataset: %s", evidence.Dataset)
		}
	}
	return nil
}
