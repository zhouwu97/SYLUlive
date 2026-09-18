package models

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"time"
)

// 工单类型常量
const (
	FeedbackTypeBug        = "bug"        // 问题反馈
	FeedbackTypeSuggestion = "suggestion" // 功能建议
	FeedbackTypeOther      = "other"      // 其他
)

// 工单处理状态常量（业务处理状态）
const (
	FeedbackStatusPending       = "pending"       // 待受理
	FeedbackStatusAccepted      = "accepted"      // 已受理
	FeedbackStatusWaitingUser   = "waiting_user"  // 待用户补充
	FeedbackStatusInvestigating = "investigating" // 定位中
	FeedbackStatusFixing        = "fixing"        // 修复中
	FeedbackStatusTesting       = "testing"       // 测试中
	FeedbackStatusResolved      = "resolved"      // 已解决
	FeedbackStatusClosed        = "closed"        // 已关闭
)

// 工单消息类型
const (
	FeedbackMsgText              = "text"               // 文本
	FeedbackMsgImage             = "image"              // 图片
	FeedbackMsgInitialSubmission = "initial_submission" // 初始提交（详情页专用展示）
	FeedbackMsgSystem            = "system"             // 系统提示
	FeedbackMsgStatusChange      = "status_change"      // 状态变更
	FeedbackMsgRequestInfo       = "request_info"       // 请求补充信息
	FeedbackMsgInternalNote      = "internal_note"      // 内部备注（仅管理员可见）
)

// 工单优先级常量
const (
	FeedbackPriorityP0 = "P0" // 紧急线上故障
	FeedbackPriorityP1 = "P1" // 重要缺陷
	FeedbackPriorityP2 = "P2" // 一般问题/建议（默认）
	FeedbackPriorityP3 = "P3" // 次要优化
)

// FeedbackTicket 工单主体模型
type FeedbackTicket struct {
	ID                 uint       `gorm:"primaryKey" json:"id"`
	TicketNo           string     `gorm:"size:32;uniqueIndex;not null" json:"ticket_no"`
	UserID             uint       `gorm:"not null;index" json:"user_id"`
	User               *User      `gorm:"foreignKey:UserID" json:"user,omitempty"`
	Type               string     `gorm:"size:20;not null;default:'bug';index" json:"type"`
	Title              string     `gorm:"size:120;not null" json:"title"`
	Description        string     `gorm:"type:text;not null" json:"description"`
	StepsToReproduce   string     `gorm:"type:text" json:"steps_to_reproduce,omitempty"`
	ActualResult       string     `gorm:"type:text" json:"actual_result,omitempty"`
	ExpectedResult     string     `gorm:"type:text" json:"expected_result,omitempty"`
	Status             string     `gorm:"size:30;not null;default:'pending';index" json:"status"`
	StatusNote         string     `gorm:"type:text" json:"status_note,omitempty"`
	Priority           string     `gorm:"size:10;not null;default:'P2';index" json:"priority"`
	AssigneeAdminID    *uint      `gorm:"index" json:"assignee_admin_id,omitempty"`
	AssigneeAdmin      *User      `gorm:"foreignKey:AssigneeAdminID" json:"assignee_admin,omitempty"`
	AdminViewed        bool       `gorm:"default:false;index" json:"admin_viewed"`
	AdminFirstViewedAt *time.Time `json:"admin_first_viewed_at,omitempty"`
	UserUnreadCount    int        `gorm:"default:0" json:"user_unread_count"`

	// 设备诊断信息快照（严格清洗，禁止包含 JWT/Cookie/密码/请求鉴权信息）
	AppVersion      string `gorm:"size:50" json:"app_version,omitempty"`
	BuildNumber     string `gorm:"size:50" json:"build_number,omitempty"`
	DeviceModel     string `gorm:"size:100" json:"device_model,omitempty"`
	OSVersion       string `gorm:"size:100" json:"os_version,omitempty"`
	NetworkType     string `gorm:"size:30" json:"network_type,omitempty"`
	CurrentRoute    string `gorm:"size:100" json:"current_route,omitempty"`
	DiagnosticsJSON string `gorm:"type:text" json:"diagnostics_json,omitempty"`

	// 冗余字段方便列表展示
	LatestReplySnippet string `gorm:"size:255" json:"latest_reply_snippet,omitempty"`

	CreatedAt  time.Time  `json:"created_at"`
	UpdatedAt  time.Time  `json:"updated_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
	ClosedAt   *time.Time `json:"closed_at,omitempty"`

	Attachments []FeedbackAttachment `gorm:"foreignKey:TicketID" json:"attachments,omitempty"`
}

// FeedbackMessage 工单流转消息与记录
type FeedbackMessage struct {
	ID            uint                 `gorm:"primaryKey" json:"id"`
	TicketID      uint                 `gorm:"not null;index" json:"ticket_id"`
	SenderType    string               `gorm:"size:20;not null;index" json:"sender_type"` // user / admin / system
	SenderID      uint                 `gorm:"not null;index" json:"sender_id"`
	Sender        *User                `gorm:"foreignKey:SenderID" json:"sender,omitempty"`
	MessageType   string               `gorm:"size:30;not null;index" json:"message_type"`
	Content       string               `gorm:"type:text;not null" json:"content"`
	MetadataJSON  string               `gorm:"type:text" json:"metadata_json,omitempty"`
	VisibleToUser bool                 `gorm:"index" json:"visible_to_user"`
	CreatedAt     time.Time            `json:"created_at"`
	Attachments   []FeedbackAttachment `gorm:"foreignKey:MessageID" json:"attachments,omitempty"`
}

// FeedbackAttachment 工单私有附件关联
type FeedbackAttachment struct {
	ID         uint      `gorm:"primaryKey" json:"id"`
	TicketID   uint      `gorm:"not null;index" json:"ticket_id"`
	MessageID  *uint     `gorm:"index" json:"message_id,omitempty"`
	FileID     uint      `gorm:"not null;index" json:"file_id"`
	File       *File     `gorm:"foreignKey:FileID" json:"file,omitempty"`
	UploaderID uint      `gorm:"not null;index" json:"uploader_id"`
	CreatedAt  time.Time `json:"created_at"`
}

// FeedbackStatusHistory 工单状态流转留痕
type FeedbackStatusHistory struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	TicketID     uint      `gorm:"not null;index" json:"ticket_id"`
	OperatorID   uint      `gorm:"not null" json:"operator_id"`
	OperatorType string    `gorm:"size:20;not null" json:"operator_type"` // user / admin / system
	OldStatus    string    `gorm:"size:30;not null" json:"old_status"`
	NewStatus    string    `gorm:"size:30;not null" json:"new_status"`
	Note         string    `gorm:"type:text" json:"note"`
	CreatedAt    time.Time `json:"created_at"`
}

// GenerateTicketNo 生成格式如 SY2609140018 的单号
func GenerateTicketNo(t time.Time) string {
	datePart := t.Format("060102") // 260914 (YYMMDD)
	n, err := rand.Int(rand.Reader, big.NewInt(9000))
	randPart := 1000
	if err == nil {
		randPart += int(n.Int64())
	}
	return fmt.Sprintf("SY%s%04d", datePart, randPart)
}
