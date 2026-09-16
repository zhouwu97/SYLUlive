package models

import (
	"time"
)

// ReportStatus 举报状态
type ReportStatus string

const (
	ReportStatusPending    ReportStatus = "pending"    // 待处理
	ReportStatusHandled    ReportStatus = "handled"    // 已处理
	ReportStatusIgnored    ReportStatus = "ignored"    // 已忽略
	ReportStatusOverturned ReportStatus = "overturned" // 申诉成功，撤销原治理决定
)

// ReportAction 管理员对内容采取的动作。warn 只记录并通知，moderated_hidden
// 保留内容供作者整改/申诉，delete 表示永久删除。
const (
	ReportActionWarn            = "warn"
	ReportActionModeratedHidden = "moderated_hidden"
	ReportActionDelete          = "delete"
)

// Report 举报
type Report struct {
	ID             uint         `gorm:"primaryKey" json:"id"`
	ReporterID     uint         `gorm:"not null;index" json:"reporter_id"`
	TargetType     string       `gorm:"size:20;not null;index" json:"target_type"` // post/reply/teacher_rating/major_rating
	TargetID       uint         `gorm:"not null;index" json:"target_id"`
	ReasonCode     string       `gorm:"size:50;index" json:"reason_code"`
	Reason         string       `gorm:"type:text;not null" json:"reason"`
	TargetAuthorID *uint        `gorm:"index" json:"target_author_id"`
	TargetSnapshot string       `gorm:"type:text" json:"target_snapshot"`
	Action            string       `gorm:"size:50" json:"action"`
	ModeratedRevision int          `gorm:"index" json:"moderated_revision,omitempty"`
	Status         ReportStatus `gorm:"default:pending;index" json:"status"`
	HandlerID      *uint        `json:"handler_id"`
	Result         string       `gorm:"size:500" json:"result"`        // 处理结果说明
	DeleteReason   string       `gorm:"size:500" json:"delete_reason"` // 删除理由
	CreatedAt      time.Time    `json:"created_at"`
	HandledAt      *time.Time   `json:"handled_at"`
	Reporter       User         `gorm:"foreignKey:ReporterID" json:"reporter"`
	Handler        *User        `gorm:"foreignKey:HandlerID" json:"handler"`
}

// AppealStatus 申诉状态
type AppealStatus string

const (
	AppealStatusPending AppealStatus = "pending"         // 待投票
	AppealStatusPass    AppealStatus = "pass"            // 申诉成功
	AppealStatusReject  AppealStatus = "reject"          // 申诉失败
	AppealStatusReview  AppealStatus = "review_required" // 平票或法定人数不足，转人工复核
)

// AppealMinRequiredVotes 是结案所需的法定票数下限。
//
// 即时结案（handlers/appeal.go）与到期兜底结案（tasks/appeal_finalizer.go）必须
// 共用同一个阈值，否则改阈值时容易只改一处，出现"投票页说够了、到期结案说不够"。
const AppealMinRequiredVotes = 5

// Appeal 申诉
type Appeal struct {
	ID                   uint         `gorm:"primaryKey" json:"id"`
	ReportID             *uint        `gorm:"uniqueIndex:idx_appeal_report;index" json:"report_id"`
	TargetType           string       `gorm:"size:20;not null;default:post" json:"target_type"`
	TargetID             uint         `gorm:"index" json:"target_id"`
	PostID               uint         `gorm:"not null" json:"post_id"`
	AppellantID          uint         `gorm:"not null" json:"appellant_id"`
	AdminID              uint         `gorm:"not null" json:"admin_id"` // 处理此举报的管理员
	AppellantReason      string       `gorm:"type:text" json:"appellant_reason"`
	EvidenceSnapshot     string       `gorm:"type:text" json:"evidence_snapshot"`
	OriginalPostStatus   PostStatus   `gorm:"size:20" json:"original_post_status"`
	OriginalTargetStatus string       `gorm:"size:20" json:"original_target_status"`
	AdminReason          string       `gorm:"size:500" json:"admin_reason"` // 管理员删除理由
	Status               AppealStatus `gorm:"default:pending" json:"status"`
	Result               string       `gorm:"size:500" json:"result"` // 最终结果
	VotingDeadline       *time.Time   `gorm:"index" json:"voting_deadline"`
	RequiredVotes        int          `gorm:"not null;default:1" json:"required_votes"`
	ClosedReason         string       `gorm:"size:100" json:"closed_reason"`
	EscalationReason     string       `gorm:"size:50" json:"escalation_reason"`
	CreatedAt            time.Time    `json:"created_at"`
	ClosedAt             *time.Time   `json:"closed_at"`
	ReviewedByID         *uint        `json:"reviewed_by_id"`
	ReviewReason         string       `gorm:"size:500" json:"review_reason"`
	ReviewedAt           *time.Time   `json:"reviewed_at"`
	Appellant            User         `gorm:"foreignKey:AppellantID" json:"appellant"`
	Admin                User         `gorm:"foreignKey:AdminID" json:"admin"`
	Post                 Post         `gorm:"foreignKey:PostID" json:"post"`
}

// AppealVote 申诉投票
type AppealVote struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	AppealID     uint      `gorm:"not null;uniqueIndex:idx_appeal_voter" json:"appeal_id"`
	VoterID      uint      `gorm:"not null;uniqueIndex:idx_appeal_voter" json:"voter_id"`
	Vote         string    `gorm:"size:10;not null" json:"vote"` // support/oppose
	Comment      string    `gorm:"size:500" json:"comment"`
	Recused      bool      `gorm:"default:false" json:"recused"`
	RecuseReason string    `gorm:"size:500" json:"-"`
	CreatedAt    time.Time `json:"created_at"`
	Voter        User      `gorm:"foreignKey:VoterID" json:"voter"`
}

// RectificationReviewStatus 整改复审状态。
type RectificationReviewStatus string

const (
	RectificationReviewPending  RectificationReviewStatus = "pending"
	RectificationReviewApproved RectificationReviewStatus = "approved"
	RectificationReviewRejected RectificationReviewStatus = "rejected"
	RectificationReviewObsolete RectificationReviewStatus = "obsolete"
)

// PostRectificationReview 记录作者提交给管理员复核的明确内容版本。
type PostRectificationReview struct {
	ID                uint                      `gorm:"primaryKey" json:"id"`
	PostID            uint                      `gorm:"not null;index" json:"post_id"`
	ReportID          *uint                     `gorm:"index" json:"report_id,omitempty"`
	SubmittedRevision int                       `gorm:"not null" json:"submitted_revision"`
	Status            RectificationReviewStatus `gorm:"size:20;not null;default:pending;index" json:"status"`
	ReviewerID        *uint                     `gorm:"index" json:"reviewer_id,omitempty"`
	ReviewReason      string                    `gorm:"size:1000" json:"review_reason,omitempty"`
	CreatedAt         time.Time                 `json:"created_at"`
	ReviewedAt        *time.Time                `json:"reviewed_at,omitempty"`
	Post              Post                      `gorm:"foreignKey:PostID" json:"post,omitempty"`
	// Report 是触发治理隐藏的举报记录，仅管理端整改待办用于回溯“为什么当初被处理”。
	// 不进 JSON：Report 含 reporter_id 与举报人自述，不属于审核依据，不能随审核响应外发。
	Report *Report `gorm:"foreignKey:ReportID;-:migration" json:"-"`
}

// PublicAppealUserResponse 是申诉接口允许展示的最小用户资料。
type PublicAppealUserResponse struct {
	ID       uint   `json:"id"`
	Nickname string `json:"nickname"`
	Avatar   string `json:"avatar"`
}

type AppealPostResponse struct {
	ID      uint       `json:"id"`
	Title   string     `json:"title"`
	Content string     `json:"content"`
	Status  PostStatus `json:"status"`
}

type AppealResponse struct {
	ID                   uint                     `json:"id"`
	ReportID             *uint                    `json:"report_id,omitempty"`
	TargetType           string                   `json:"target_type"`
	TargetID             uint                     `json:"target_id"`
	PostID               uint                     `json:"post_id"`
	AppellantReason      string                   `json:"appellant_reason"`
	EvidenceSnapshot     string                   `json:"evidence_snapshot,omitempty"`
	OriginalPostStatus   PostStatus               `json:"original_post_status,omitempty"`
	OriginalTargetStatus string                   `json:"original_target_status,omitempty"`
	AdminReason          string                   `json:"admin_reason"`
	Status               AppealStatus             `json:"status"`
	Result               string                   `json:"result"`
	VotingDeadline       *time.Time               `json:"voting_deadline"`
	RequiredVotes        int                      `json:"required_votes"`
	ClosedReason         string                   `json:"closed_reason"`
	EscalationReason     string                   `json:"escalation_reason,omitempty"`
	CreatedAt            time.Time                `json:"created_at"`
	ClosedAt             *time.Time               `json:"closed_at"`
	ReviewedByID         *uint                    `json:"reviewed_by_id,omitempty"`
	ReviewReason         string                   `json:"review_reason,omitempty"`
	ReviewedAt           *time.Time               `json:"reviewed_at,omitempty"`
	Appellant            PublicAppealUserResponse `json:"appellant"`
	Admin                PublicAppealUserResponse `json:"admin"`
	Post                 AppealPostResponse       `json:"post"`
	CanVote              bool                     `json:"can_vote"`
	CanRecuse            bool                     `json:"can_recuse"`
	IsRecused            bool                     `json:"is_recused"`
	IsAppellant          bool                     `json:"is_appellant"`
	IsAdmin              bool                     `json:"is_admin"`
	MyVote               string                   `json:"my_vote,omitempty"`
	HasVoted             bool                     `json:"has_voted"`
	CastCount            int                      `json:"cast_count,omitempty"`
	SupportCount         int                      `json:"support_count,omitempty"`
	OpposeCount          int                      `json:"oppose_count,omitempty"`
}

type AppealVoteResponse struct {
	ID        uint                     `json:"id"`
	AppealID  uint                     `json:"appeal_id"`
	Vote      string                   `json:"vote"`
	Comment   string                   `json:"comment"`
	Recused   bool                     `json:"recused"`
	CreatedAt time.Time                `json:"created_at"`
	Voter     PublicAppealUserResponse `json:"voter"`
}

// PublicAppealResponse 结案公示 DTO，不包含当事人、管理员或陪审员身份。
type PublicAppealResponse struct {
	ID               uint         `json:"id"`
	PostTitle        string       `json:"post_title"`
	Status           AppealStatus `json:"status"`
	Result           string       `json:"result"`
	ResolutionSource string       `json:"resolution_source"`
	ClosedReason     string       `json:"closed_reason"`
	EscalationReason string       `json:"escalation_reason,omitempty"`
	ClosedAt         *time.Time   `json:"closed_at"`
	CreatedAt        time.Time    `json:"created_at"`
	SupportCount     int          `json:"support_count"`
	OpposeCount      int          `json:"oppose_count"`
}
