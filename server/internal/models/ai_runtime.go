package models

import (
	"time"

	"gorm.io/datatypes"
	"gorm.io/gorm"
)

const (
	AIRunStateCreated             = "created"
	AIRunStateBudgetReserved      = "budget_reserved"
	AIRunStateRetrieving          = "retrieving"
	AIRunStatePlanning            = "planning"
	AIRunStateToolRequested       = "tool_requested"
	AIRunStateToolExecuting       = "tool_executing"
	AIRunStateToolCompleted       = "tool_completed"
	AIRunStateWaitingDevice       = "waiting_device"
	AIRunStateWaitingUserConsent  = "waiting_user_consent"
	AIRunStateWaitingEdu          = "waiting_edu"
	AIRunStateAwaitingClientTool  = "awaiting_client_tool"
	AIRunStateExecutingServerTool = "executing_server_tool"
	AIRunStateGenerating          = "generating"
	AIRunStateCompleted           = "completed"
	AIRunStateFailed              = "failed"
	AIRunStateCancelled           = "cancelled"
	AIRunStateExpired             = "expired"
)

// AIConversation 是 AI 对话的独立命名空间，不能与站内私信 Conversation 混用。
type AIConversation struct {
	ID        string         `gorm:"type:varchar(36);primaryKey" json:"id"`
	UserID    uint           `gorm:"not null;index:idx_ai_conversations_user_updated,priority:1" json:"user_id"`
	Title     string         `gorm:"size:80;not null;default:''" json:"title"`
	CreatedAt time.Time      `json:"created_at"`
	UpdatedAt time.Time      `gorm:"index:idx_ai_conversations_user_updated,priority:2" json:"updated_at"`
	DeletedAt gorm.DeletedAt `gorm:"index" json:"-"`
}

func (AIConversation) TableName() string { return "ai_conversations" }

// AIConversationMessage 保存用户主动保留的会话正文。运行审计表不复制这些原文。
type AIConversationMessage struct {
	ID             string    `gorm:"type:varchar(36);primaryKey" json:"id"`
	ConversationID string    `gorm:"type:varchar(36);not null;index:idx_ai_messages_conversation_created,priority:1" json:"conversation_id"`
	RunID          *string   `gorm:"type:varchar(36);index" json:"run_id,omitempty"`
	Role           string    `gorm:"size:16;not null" json:"role"`
	Content        string    `gorm:"type:text;not null" json:"content"`
	CreatedAt      time.Time `gorm:"index:idx_ai_messages_conversation_created,priority:2" json:"created_at"`
}

func (AIConversationMessage) TableName() string { return "ai_conversation_messages" }

// AIRun 是一次正式请求的唯一状态载体。ClientRequestID 与用户联合唯一，保证幂等。
type AIRun struct {
	ID                  string     `gorm:"type:varchar(36);primaryKey" json:"id"`
	UserID              uint       `gorm:"not null;uniqueIndex:idx_ai_runs_user_request,priority:1;index" json:"user_id"`
	ConversationID      string     `gorm:"type:varchar(36);not null;index" json:"conversation_id"`
	ClientRequestID     string     `gorm:"type:varchar(36);not null;uniqueIndex:idx_ai_runs_user_request,priority:2" json:"client_request_id"`
	State               string     `gorm:"size:32;not null;index" json:"state"`
	StateVersion        int64      `gorm:"not null;default:0" json:"state_version"`
	Provider            string     `gorm:"size:32;not null" json:"provider"`
	Model               string     `gorm:"size:100;not null" json:"model"`
	Attempt             int        `gorm:"not null;default:1" json:"attempt"`
	MessageHash         string     `gorm:"size:64;not null" json:"-"`
	MessageLength       int        `gorm:"not null" json:"message_length"`
	BudgetReservationID *string    `gorm:"type:varchar(36);index" json:"-"`
	LastEventSeq        int64      `gorm:"not null;default:0" json:"last_event_seq"`
	AnswerCheckpoint    string     `gorm:"type:text;not null;default:''" json:"answer_checkpoint,omitempty"`
	ErrorCode           string     `gorm:"size:64;not null;default:''" json:"error_code,omitempty"`
	CancelledAt         *time.Time `json:"cancelled_at,omitempty"`
	ExpiresAt           time.Time  `gorm:"not null;index" json:"expires_at"`
	StartedAt           *time.Time `json:"started_at,omitempty"`
	CompletedAt         *time.Time `json:"completed_at,omitempty"`
	CreatedAt           time.Time  `gorm:"index" json:"created_at"`
	UpdatedAt           time.Time  `json:"updated_at"`
}

func (AIRun) TableName() string { return "ai_runs" }

// AIEvent 只保存可恢复事件；逐 token 增量与 heartbeat 只存在于内存流。
type AIEvent struct {
	ID        uint64         `gorm:"primaryKey" json:"-"`
	RunID     string         `gorm:"type:varchar(36);not null;uniqueIndex:idx_ai_events_run_seq,priority:1;index" json:"run_id"`
	Seq       int64          `gorm:"not null;uniqueIndex:idx_ai_events_run_seq,priority:2" json:"seq"`
	Type      string         `gorm:"size:48;not null" json:"type"`
	Payload   datatypes.JSON `gorm:"type:jsonb;not null" json:"payload"`
	CreatedAt time.Time      `json:"timestamp"`
}

func (AIEvent) TableName() string { return "ai_events" }

// AIToolCall 记录经过服务端 Schema 与权限校验的工具调用。
type AIToolCall struct {
	CallID        string         `gorm:"type:varchar(100);primaryKey" json:"call_id"`
	RunID         string         `gorm:"type:varchar(36);not null;index" json:"run_id"`
	UserID        uint           `gorm:"not null;index" json:"user_id"`
	ToolName      string         `gorm:"size:100;not null" json:"tool_name"`
	ToolVersion   string         `gorm:"size:32;not null" json:"tool_version"`
	ArgumentsJSON datatypes.JSON `gorm:"type:jsonb;not null" json:"arguments"`
	ArgumentsHash string         `gorm:"size:64;not null" json:"-"`
	Status        string         `gorm:"size:24;not null;index" json:"status"`
	StateVersion  int64          `gorm:"not null;default:0" json:"state_version"`
	ExpiresAt     time.Time      `gorm:"not null;index" json:"expires_at"`
	ResultJSON    datatypes.JSON `gorm:"type:jsonb" json:"result,omitempty"`
	ResultHash    string         `gorm:"size:64" json:"-"`
	CreatedAt     time.Time      `json:"created_at"`
	CompletedAt   *time.Time     `json:"completed_at,omitempty"`
}

func (AIToolCall) TableName() string { return "ai_tool_calls" }

// AIRunResumeJob 保存等待外部操作时恢复 Provider 所需的最小上下文。
// 消息只在等待期内保留，外部操作完成或 Run 终止后会立即删除，避免把个人数据长期留存。
type AIRunResumeJob struct {
	ID                   string         `gorm:"type:varchar(36);primaryKey" json:"id"`
	RunID                string         `gorm:"type:varchar(36);not null;uniqueIndex" json:"run_id"`
	UserID               uint           `gorm:"not null;index" json:"-"`
	WaitingState         string         `gorm:"size:32;not null;index" json:"waiting_state"`
	MessagesJSON         datatypes.JSON `gorm:"type:jsonb;not null" json:"-"`
	PendingToolCallsJSON datatypes.JSON `gorm:"type:jsonb;not null" json:"-"`
	UsageJSON            datatypes.JSON `gorm:"type:jsonb;not null" json:"-"`
	Status               string         `gorm:"size:24;not null;index" json:"status"`
	ExpiresAt            time.Time      `gorm:"not null;index" json:"expires_at"`
	CreatedAt            time.Time      `json:"created_at"`
	UpdatedAt            time.Time      `json:"updated_at"`
}

func (AIRunResumeJob) TableName() string { return "ai_run_resume_jobs" }

// AIActionDraft 是 AI 可创建、但只能由所属用户确认的操作草稿。
// 第一版仅支持将单个官方赛事加入竞赛计划。
type AIActionDraft struct {
	ID     uint `gorm:"primaryKey" json:"id"`
	UserID uint `gorm:"not null;index;uniqueIndex:idx_ai_action_draft_user_key,priority:1" json:"-"`

	ActionType string `gorm:"size:64;not null;index" json:"action_type"`
	Status     string `gorm:"size:24;not null;index" json:"status"`

	CompetitionEventID       uint `gorm:"not null;index" json:"competition_event_id"`
	RecommendationSnapshotID uint `gorm:"not null;index" json:"recommendation_snapshot_id"`

	PayloadHash    string `gorm:"size:64;not null" json:"-"`
	IdempotencyKey string `gorm:"size:100;not null;uniqueIndex:idx_ai_action_draft_user_key,priority:2" json:"-"`

	CreatedAt   time.Time  `json:"created_at"`
	ExpiresAt   time.Time  `gorm:"not null;index" json:"expires_at"`
	ConfirmedAt *time.Time `json:"confirmed_at,omitempty"`
	ExecutedAt  *time.Time `json:"executed_at,omitempty"`
	CancelledAt *time.Time `json:"cancelled_at,omitempty"`

	ResultResourceType string `gorm:"size:64" json:"result_resource_type,omitempty"`
	ResultResourceID   *uint  `gorm:"index" json:"result_resource_id,omitempty"`
	FailureReason      string `gorm:"size:200" json:"failure_reason,omitempty"`
}

func (AIActionDraft) TableName() string { return "ai_action_drafts" }

// AIActionAuditLog 只记录草稿状态动作，不保存完整 AI 对话或个人画像。
type AIActionAuditLog struct {
	ID      uint `gorm:"primaryKey" json:"id"`
	DraftID uint `gorm:"not null;index" json:"draft_id"`
	UserID  uint `gorm:"not null;index" json:"user_id"`

	Action          string    `gorm:"size:32;not null;index" json:"action"`
	CreatedAt       time.Time `gorm:"index" json:"created_at"`
	ClientRequestID string    `gorm:"size:100" json:"client_request_id,omitempty"`
	Result          string    `gorm:"size:100" json:"result"`
}

func (AIActionAuditLog) TableName() string { return "ai_action_audit_logs" }

// AIQuotaEntry 同时承担并发占位和滚动窗口计数；失败且尚未生成的请求会被释放。
type AIQuotaEntry struct {
	ID         uint64     `gorm:"primaryKey" json:"-"`
	UserID     uint       `gorm:"not null;index:idx_ai_quota_user_created,priority:1" json:"user_id"`
	RunID      string     `gorm:"type:varchar(36);not null;uniqueIndex" json:"run_id"`
	Status     string     `gorm:"size:16;not null;index" json:"status"`
	CreatedAt  time.Time  `gorm:"index:idx_ai_quota_user_created,priority:2" json:"created_at"`
	ReleasedAt *time.Time `json:"released_at,omitempty"`
}

func (AIQuotaEntry) TableName() string { return "ai_quota_entries" }

// AIUserBudget 的金额单位均为人民币微元，避免浮点舍入。
type AIUserBudget struct {
	UserID            uint      `gorm:"primaryKey" json:"user_id"`
	LimitMicroYuan    int64     `gorm:"not null" json:"limit_micro_yuan"`
	UsedMicroYuan     int64     `gorm:"not null;default:0" json:"used_micro_yuan"`
	ReservedMicroYuan int64     `gorm:"not null;default:0" json:"reserved_micro_yuan"`
	CreatedAt         time.Time `json:"created_at"`
	UpdatedAt         time.Time `json:"updated_at"`
}

func (AIUserBudget) TableName() string { return "ai_user_budgets" }

type AIBudgetReservation struct {
	ID                string     `gorm:"type:varchar(36);primaryKey" json:"id"`
	RunID             string     `gorm:"type:varchar(36);not null;uniqueIndex" json:"run_id"`
	UserID            uint       `gorm:"not null;index" json:"user_id"`
	ReservedMicroYuan int64      `gorm:"not null" json:"reserved_micro_yuan"`
	ActualMicroYuan   int64      `gorm:"not null;default:0" json:"actual_micro_yuan"`
	Status            string     `gorm:"size:16;not null;index" json:"status"`
	ExpiresAt         time.Time  `gorm:"not null;index" json:"expires_at"`
	SettledAt         *time.Time `json:"settled_at,omitempty"`
	CreatedAt         time.Time  `json:"created_at"`
}

func (AIBudgetReservation) TableName() string { return "ai_budget_reservations" }

// AIUsageRecord 只保存计量，不保存问题、提示词或完整工具结果。
type AIUsageRecord struct {
	ID                  uint64    `gorm:"primaryKey" json:"id"`
	RunID               string    `gorm:"type:varchar(36);not null;uniqueIndex" json:"run_id"`
	UserHash            string    `gorm:"size:64;not null;index" json:"user_hash"`
	Provider            string    `gorm:"size:32;not null" json:"provider"`
	Model               string    `gorm:"size:100;not null" json:"model"`
	InputTokens         int       `gorm:"not null;default:0" json:"input_tokens"`
	OutputTokens        int       `gorm:"not null;default:0" json:"output_tokens"`
	CacheHitTokens      int       `gorm:"not null;default:0" json:"cache_hit_tokens"`
	CostMicroYuan       int64     `gorm:"not null;default:0" json:"cost_micro_yuan"`
	LatencyMilliseconds int64     `gorm:"not null;default:0" json:"latency_ms"`
	ErrorClass          string    `gorm:"size:64;not null;default:''" json:"error_class,omitempty"`
	Purpose             string    `gorm:"size:32;not null;default:'campus_agent';index" json:"purpose"`
	CreatedAt           time.Time `gorm:"index" json:"created_at"`
}

func (AIUsageRecord) TableName() string { return "ai_usage_records" }

// ClassPeriodProfile 是人工审核后的节次钟点映射；课表 Skill 不允许自行猜测时间。
type ClassPeriodProfile struct {
	ID            uint           `gorm:"primaryKey" json:"id"`
	AcademicYear  string         `gorm:"size:20;not null;index" json:"academic_year"`
	Name          string         `gorm:"size:100;not null" json:"name"`
	Status        string         `gorm:"size:20;not null;index" json:"status"`
	Periods       datatypes.JSON `gorm:"type:jsonb;not null" json:"periods"`
	EffectiveFrom time.Time      `gorm:"not null;index" json:"effective_from"`
	EffectiveTo   time.Time      `gorm:"not null;index" json:"effective_to"`
	CreatedBy     uint           `gorm:"not null;index" json:"created_by"`
	PublishedBy   uint           `gorm:"index" json:"published_by,omitempty"`
	PublishedAt   *time.Time     `json:"published_at,omitempty"`
	CreatedAt     time.Time      `json:"created_at"`
	UpdatedAt     time.Time      `json:"updated_at"`
}

func (ClassPeriodProfile) TableName() string { return "class_period_profiles" }
