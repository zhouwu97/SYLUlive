package models

import (
	"time"
)

// BoardID 板块ID
type BoardID int

const (
	BoardShuitie BoardID = 1 // 水贴
	BoardMarket  BoardID = 2 // 校园集市
	BoardScam    BoardID = 3 // 骗子曝光（占位）
	BoardNotice  BoardID = 4 // 公告
)

// PostStatus 帖子状态
type PostStatus string

const (
	PostStatusNormal  PostStatus = "normal"  // 正常
	PostStatusDeleted PostStatus = "deleted" // 已删除
)

// Post 帖子模型
type Post struct {
	ID             uint        `gorm:"primaryKey" json:"id"`
	Title          string      `gorm:"size:200" json:"title"`              // 标题（水贴可为空）
	Content        string      `gorm:"type:text" json:"content"`           // Markdown内容
	BoardID        BoardID     `gorm:"not null;index" json:"board_id"`     // 板块ID
	AuthorID       uint        `gorm:"not null;index" json:"author_id"`    // 作者ID
	PostType       string      `gorm:"size:50;index" json:"post_type"`     // marketplace_buy/sell, course_proxy 等
	Price          float64     `gorm:"default:0" json:"price"`             // 价格（校园集市用）
	Contact        string      `gorm:"size:500" json:"contact"`            // 联系方式
	Status         PostStatus  `gorm:"default:normal;index" json:"status"` // 状态
	ViewCount      int         `gorm:"default:0" json:"view_count"`        // 观看次数
	ReplyCount     int         `gorm:"default:0" json:"reply_count"`       // 回复数量
	LikeCount      int         `gorm:"default:0" json:"like_count"`        // 点赞数量
	IsLiked        bool        `gorm:"-" json:"is_liked"`                  // 当前用户是否已赞
	IsPinned       bool        `gorm:"default:false;index" json:"is_pinned"`
	PinnedAt       *time.Time  `gorm:"index" json:"pinned_at"`
	PinnedUntil    *time.Time  `gorm:"index" json:"pinned_until"`
	PinnedBy       uint        `gorm:"index" json:"pinned_by"`
	PinnedWeight   int         `gorm:"default:0;index" json:"pinned_weight"`
	PinnedReason   string      `gorm:"size:500" json:"pinned_reason"`
	IsFeatured     bool        `gorm:"default:false;index" json:"is_featured"`
	FeaturedAt     *time.Time  `json:"featured_at"`
	FeaturedBy     uint        `gorm:"index" json:"featured_by"`
	FeaturedReason string      `gorm:"size:500" json:"featured_reason"`
	Images         []PostImage `gorm:"foreignKey:PostID" json:"images"`
	Author         User        `gorm:"foreignKey:AuthorID" json:"author"`
	CreatedAt      time.Time   `json:"created_at"`
	UpdatedAt      time.Time   `json:"updated_at"`
}

// PostImage 帖子图片关联
type PostImage struct {
	ID        uint `gorm:"primaryKey" json:"id"`
	PostID    uint `gorm:"not null" json:"post_id"`
	FileID    uint `gorm:"not null" json:"file_id"`
	SortOrder int  `gorm:"default:0" json:"sort_order"`
	File      File `gorm:"foreignKey:FileID" json:"file"`
}

type FeaturedApplication struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	PostID        uint       `gorm:"not null;index" json:"post_id"`
	ApplicantID   uint       `gorm:"not null;index" json:"applicant_id"`
	Reason        string     `gorm:"size:1000" json:"reason"`
	Status        string     `gorm:"size:20;default:'pending';index" json:"status"`
	ReviewerID    uint       `gorm:"index" json:"reviewer_id"`
	ReviewReason  string     `gorm:"size:1000" json:"review_reason"`
	IsMalicious   bool       `gorm:"default:false" json:"is_malicious"`
	PenaltyPoints int        `gorm:"default:0" json:"penalty_points"`
	CreatedAt     time.Time  `json:"created_at"`
	ReviewedAt    *time.Time `json:"reviewed_at"`
	Post          Post       `gorm:"foreignKey:PostID" json:"post,omitempty"`
	Applicant     User       `gorm:"foreignKey:ApplicantID" json:"applicant,omitempty"`
	Reviewer      User       `gorm:"foreignKey:ReviewerID" json:"reviewer,omitempty"`
}

func (FeaturedApplication) TableName() string { return "featured_applications" }

type CollaborationApplication struct {
	ID          uint       `gorm:"primaryKey" json:"id"`
	PostID      uint       `gorm:"not null;index" json:"post_id"`
	ApplicantID uint       `gorm:"not null;index" json:"applicant_id"`
	OwnerID     uint       `gorm:"not null;index" json:"owner_id"`
	Reason      string     `gorm:"size:1000" json:"reason"`
	Status      string     `gorm:"size:20;default:'pending';index" json:"status"`
	OwnerReply  string     `gorm:"size:1000" json:"owner_reply"`
	CreatedAt   time.Time  `json:"created_at"`
	ReviewedAt  *time.Time `json:"reviewed_at"`
	Post        Post       `gorm:"foreignKey:PostID" json:"post,omitempty"`
	Applicant   User       `gorm:"foreignKey:ApplicantID" json:"applicant,omitempty"`
	Owner       User       `gorm:"foreignKey:OwnerID" json:"owner,omitempty"`
}

func (CollaborationApplication) TableName() string { return "collaboration_applications" }

type PostRevisionProposal struct {
	ID                         uint       `gorm:"primaryKey" json:"id"`
	PostID                     uint       `gorm:"not null;index" json:"post_id"`
	CollaborationApplicationID uint       `gorm:"not null;index" json:"collaboration_application_id"`
	ProposerID                 uint       `gorm:"not null;index" json:"proposer_id"`
	OwnerID                    uint       `gorm:"not null;index" json:"owner_id"`
	BaseTitle                  string     `gorm:"size:200" json:"base_title"`
	BaseContent                string     `gorm:"type:text" json:"base_content"`
	BasePostUpdatedAt          time.Time  `gorm:"index" json:"base_post_updated_at"`
	ProposedTitle              string     `gorm:"size:200" json:"proposed_title"`
	ProposedContent            string     `gorm:"type:text" json:"proposed_content"`
	ChangeSummary              string     `gorm:"size:1000" json:"change_summary"`
	Status                     string     `gorm:"size:20;default:'pending';index" json:"status"`
	OwnerReply                 string     `gorm:"size:1000" json:"owner_reply"`
	CreatedAt                  time.Time  `json:"created_at"`
	ReviewedAt                 *time.Time `json:"reviewed_at"`
	PublishedAt                *time.Time `json:"published_at"`
	Post                       Post       `gorm:"foreignKey:PostID" json:"post,omitempty"`
	Proposer                   User       `gorm:"foreignKey:ProposerID" json:"proposer,omitempty"`
	Owner                      User       `gorm:"foreignKey:OwnerID" json:"owner,omitempty"`
}

func (PostRevisionProposal) TableName() string { return "post_revision_proposals" }

type ReputationLog struct {
	ID         uint      `gorm:"primaryKey" json:"id"`
	UserID     uint      `gorm:"not null;index" json:"user_id"`
	OperatorID uint      `gorm:"index" json:"operator_id"`
	Action     string    `gorm:"size:80;index" json:"action"`
	Delta      int       `json:"delta"`
	Reason     string    `gorm:"size:1000" json:"reason"`
	RefType    string    `gorm:"size:80;index" json:"ref_type"`
	RefID      uint      `gorm:"index" json:"ref_id"`
	CreatedAt  time.Time `json:"created_at"`
	User       User      `gorm:"foreignKey:UserID" json:"user,omitempty"`
	Operator   User      `gorm:"foreignKey:OperatorID" json:"operator,omitempty"`
}

func (ReputationLog) TableName() string { return "reputation_logs" }
