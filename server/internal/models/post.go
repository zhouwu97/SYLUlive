package models

import (
	"encoding/json"
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

// MarketContactType 集市外部联系方式类型。
type MarketContactType string

const (
	MarketContactTypeWeChat MarketContactType = "wechat"
	MarketContactTypeQQ     MarketContactType = "qq"
	MarketContactTypePhone  MarketContactType = "phone"
	// MarketContactTypeOther 仅用于无法可靠识别的历史数据。
	MarketContactTypeOther MarketContactType = "other"
)

// PostStatus 帖子状态
type PostStatus string

const (
	PostStatusNormal  PostStatus = "normal"  // 正常 / 出售中
	PostStatusSold    PostStatus = "sold"    // 已售出，保留历史记录
	PostStatusClosed  PostStatus = "closed"  // 已关闭，保留历史记录
	PostStatusDeleted PostStatus = "deleted" // 已删除
)

// PostContentKind 区分普通帖子与复用帖子能力的特殊内容。
type PostContentKind string

const (
	PostContentKindNormal PostContentKind = "normal"
	PostContentKindPoll   PostContentKind = "poll"
)

// Post 帖子模型
type Post struct {
	ID       uint    `gorm:"primaryKey" json:"id"`
	Title    string  `gorm:"size:200" json:"title"`           // 标题（水贴可为空）
	Content  string  `gorm:"type:text" json:"content"`        // Markdown内容
	BoardID  BoardID `gorm:"not null;index" json:"board_id"`  // 板块ID
	AuthorID uint    `gorm:"not null;index" json:"author_id"` // 作者ID
	// PostType 板块相关类型：
	//   board_id = BoardShuitie 时，post_type 表示 WaterSection.Slug（如 course_study）。
	//   board_id = BoardMarket 时，post_type 仍为 marketplace_buy / marketplace_sell 等旧语义。
	PostType    string            `gorm:"size:50;index" json:"post_type"`
	ContentKind PostContentKind   `gorm:"size:20;not null;default:'normal';index" json:"content_kind"`
	Price       float64           `gorm:"default:0" json:"price"`                       // 价格（校园集市用）
	ContactType MarketContactType `gorm:"size:20;default:'';index" json:"contact_type"` // 联系方式类型
	Contact     string            `gorm:"size:500" json:"contact"`                      // 联系账号
	MarketTags  string            `gorm:"size:200" json:"market_tags"`                  // 商品交易选项，逗号分隔
	// WaterTagID 水帖版块内标签 ID，仅在 board_id = BoardShuitie 时使用；旧帖子与旧客户端可不传。
	WaterTagID             *uint      `gorm:"index" json:"water_tag_id"`
	Status                 PostStatus `gorm:"default:normal;index" json:"status"` // 状态
	ViewCount              int        `gorm:"default:0" json:"view_count"`        // 观看次数
	ReplyCount             int        `gorm:"default:0" json:"reply_count"`       // 回复数量
	LikeCount              int        `gorm:"default:0" json:"like_count"`        // 点赞数量
	IsLiked                bool       `gorm:"-" json:"is_liked"`                  // 当前用户是否已赞
	IsPinned               bool       `gorm:"default:false;index" json:"is_pinned"`
	PinnedAt               *time.Time `gorm:"index" json:"pinned_at"`
	PinnedUntil            *time.Time `gorm:"index" json:"pinned_until"`
	PinnedBy               uint       `gorm:"index" json:"pinned_by"`
	PinnedWeight           int        `gorm:"default:0;index" json:"pinned_weight"`
	PinnedReason           string     `gorm:"size:500" json:"pinned_reason"`
	IsFeatured             bool       `gorm:"default:false;index" json:"is_featured"`
	FeaturedAt             *time.Time `json:"featured_at"`
	FeaturedBy             uint       `gorm:"index" json:"featured_by"`
	FeaturedReason         string     `gorm:"size:500" json:"featured_reason"`
	WaterSectionPinned     bool       `gorm:"-" json:"water_section_pinned"`
	WaterSectionPinID      *uint      `gorm:"-" json:"water_section_pin_id,omitempty"`
	WaterSectionFeatured   bool       `gorm:"-" json:"water_section_featured"`
	WaterSectionFeaturedID *uint      `gorm:"-" json:"water_section_featured_id,omitempty"`
	HomeFeaturedPending    bool       `gorm:"-" json:"home_featured_pending,omitempty"`

	// 统一经验返回字段
	ExpEarned int `gorm:"-" json:"exp_earned,omitempty"`
	// ExpAwards 发帖/评论成功后本次下发的经验奖励，前端用于弹出"+10经验"提示。
	// 旧客户端会忽略此字段；新增为空时不输出。
	ExpAwards              []ExpAward              `gorm:"-" json:"exp_awards,omitempty"`
	WaterSectionAuthorMeta *WaterSectionAuthorMeta `gorm:"-" json:"water_section_author_meta,omitempty"`
	TeamRecruitmentMeta    *TeamRecruitmentMeta    `gorm:"-" json:"team_recruitment_meta,omitempty"`
	PollMeta               *PollSummaryDTO         `gorm:"-" json:"poll_meta,omitempty"`
	Topics                 []TopicBrief            `gorm:"-" json:"topics"`
	Images                 []PostImage             `gorm:"foreignKey:PostID" json:"images"`
	Author                 User                    `gorm:"foreignKey:AuthorID" json:"author"`
	CreatedAt              time.Time               `json:"created_at"`
	UpdatedAt              time.Time               `json:"updated_at"`
	// LastActivityAt 是最后一条有效回复的时间；无回复时等于发帖时间，不能用正文编辑时间替代。
	LastActivityAt time.Time `gorm:"index" json:"last_activity_at"`
}

// MarshalJSON 确保帖子作者始终使用公开 DTO，而非数据库 User 模型。
func (p Post) MarshalJSON() ([]byte, error) {
	type postAlias Post
	return json.Marshal(struct {
		postAlias
		Author PublicUserResponse `json:"author"`
	}{
		postAlias: postAlias(p),
		Author:    PublicUser(p.Author),
	})
}

// TeamRecruitmentMeta 组队招募前端所需数据
type TeamRecruitmentMeta struct {
	RecruitmentID       uint       `json:"recruitment_id"`
	NeededCount         int        `json:"needed_count"`
	AcceptedCount       int        `json:"accepted_count"`
	RemainingCount      int        `json:"remaining_count"`
	Roles               []string   `json:"roles"`
	Deadline            *time.Time `json:"deadline"`
	Status              string     `json:"status"`
	EffectiveStatus     string     `json:"effective_status"`
	ApplicationCount    int64      `json:"application_count"`
	MyApplicationStatus *string    `json:"my_application_status"`
	IsOwner             bool       `json:"is_owner"`
	CanApply            bool       `json:"can_apply"`
	CanManage           bool       `json:"can_manage"`
}

// PostImage 帖子图片关联
type PostImage struct {
	ID        uint `gorm:"primaryKey" json:"id"`
	PostID    uint `gorm:"not null" json:"post_id"`
	FileID    uint `gorm:"not null" json:"file_id"`
	SortOrder int  `gorm:"default:0" json:"sort_order"`
	File      File `gorm:"foreignKey:FileID" json:"file"`
	// 这是跨 PostImage/ReplyImage 共用 FileID 的逻辑关联，不能让 GORM 为其创建
	// 外键，否则 image_variants.file_id 会被错误地同时指向两个父表。
	Variants []ImageVariant `gorm:"foreignKey:FileID;references:FileID;-:migration" json:"-"`
}

// MarshalJSON 为客户端提供统一的三档图片地址契约。
func (image PostImage) MarshalJSON() ([]byte, error) {
	type postImageJSON struct {
		ID            uint              `json:"id"`
		PostID        uint              `json:"post_id"`
		FileID        uint              `json:"file_id"`
		SortOrder     int               `json:"sort_order"`
		File          File              `json:"file"`
		ThumbURL      string            `json:"thumb_url,omitempty"`
		MediumURL     string            `json:"medium_url,omitempty"`
		OriginURL     string            `json:"origin_url,omitempty"`
		VariantStatus map[string]string `json:"variant_status"`
	}
	variantStatus := make(map[string]string, len(image.Variants))
	for _, variant := range image.Variants {
		if variant.RecipeVersion != 1 || (variant.Variant != "thumb" && variant.Variant != "medium") {
			continue
		}
		variantStatus[variant.Variant] = string(variant.Status)
	}
	return json.Marshal(postImageJSON{
		ID: image.ID, PostID: image.PostID, FileID: image.FileID,
		SortOrder: image.SortOrder, File: image.File,
		ThumbURL:      postImageVariantURL(image.File.Path, image.Variants, "thumb"),
		MediumURL:     postImageVariantURL(image.File.Path, image.Variants, "medium"),
		OriginURL:     image.File.Path,
		VariantStatus: variantStatus,
	})
}

func postImageVariantURL(originURL string, variants []ImageVariant, variantName string) string {
	for _, variant := range variants {
		if variant.Variant == variantName && variant.RecipeVersion == 1 &&
			variant.Status == ImageVariantStatusReady && variant.Path != "" {
			return variant.Path
		}
	}
	return originURL
}

type FeaturedApplication struct {
	ID                uint       `gorm:"primaryKey" json:"id"`
	PostID            uint       `gorm:"not null;index" json:"post_id"`
	ApplicantID       uint       `gorm:"not null;index" json:"applicant_id"`
	Source            string     `gorm:"size:32;default:'user'" json:"source"`
	SectionID         *uint      `gorm:"index" json:"section_id"`
	SectionFeaturedID *uint      `gorm:"index" json:"section_featured_id"`
	Reason            string     `gorm:"size:1000" json:"reason"`
	Status            string     `gorm:"size:20;default:'pending';index" json:"status"`
	ReviewerID        *uint      `gorm:"index" json:"reviewer_id,omitempty"`
	ReviewReason      string     `gorm:"size:1000" json:"review_reason"`
	IsMalicious       bool       `gorm:"default:false" json:"is_malicious"`
	PenaltyPoints     int        `gorm:"default:0" json:"penalty_points"`
	CreatedAt         time.Time  `json:"created_at"`
	ReviewedAt        *time.Time `json:"reviewed_at"`
	Post              Post       `gorm:"foreignKey:PostID" json:"post,omitempty"`
	Applicant         User       `gorm:"foreignKey:ApplicantID" json:"applicant,omitempty"`
	Reviewer          *User      `gorm:"foreignKey:ReviewerID" json:"reviewer,omitempty"`
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
