package models

import (
	"time"

	"gorm.io/gorm"
)

const (
	// CanteenOperatingActive 表示食堂正常营业，可参与新评价、排行和推荐。
	CanteenOperatingActive = "active"
	// CanteenOperatingOffline 表示食堂暂时下架，历史数据保留但不参与当前发现体系。
	CanteenOperatingOffline = "offline"
)

// 食堂位置系统标签：区域（一食堂/二食堂）与楼层（一楼/二楼）。
// 店铺名只保留纯店铺名，位置信息由这两个结构化字段表达。
const (
	CanteenLocationArea1  = "一食堂"
	CanteenLocationArea2  = "二食堂"
	CanteenLocationFloor1 = "一楼"
	CanteenLocationFloor2 = "二楼"
)

// CanteenLocationAreas 区域标签可选值。新增食堂区域时在此扩展。
var CanteenLocationAreas = []string{CanteenLocationArea1, CanteenLocationArea2}

// CanteenLocationFloors 楼层标签可选值。新增楼层时在此扩展。
var CanteenLocationFloors = []string{CanteenLocationFloor1, CanteenLocationFloor2}

// IsValidCanteenLocationArea 校验区域标签是否为合法可选值（空值表示未填写）。
func IsValidCanteenLocationArea(v string) bool {
	if v == "" {
		return true
	}
	for _, area := range CanteenLocationAreas {
		if area == v {
			return true
		}
	}
	return false
}

// IsValidCanteenLocationFloor 校验楼层标签是否为合法可选值（空值表示未填写）。
func IsValidCanteenLocationFloor(v string) bool {
	if v == "" {
		return true
	}
	for _, floor := range CanteenLocationFloors {
		if floor == v {
			return true
		}
	}
	return false
}

// Canteen 食堂/店铺
type Canteen struct {
	ID              uint       `gorm:"primaryKey" json:"id"`
	Name            string     `gorm:"size:100;not null;index" json:"name"`
	NormalizedName  string     `gorm:"size:100;not null;default:''" json:"-"`
	LocationArea    string     `gorm:"size:20;not null;default:''" json:"location_area"`
	LocationFloor   string     `gorm:"size:20;not null;default:''" json:"location_floor"`
	Image           string     `gorm:"size:500;not null" json:"image"` // 封面图
	Verified        bool       `gorm:"default:false" json:"verified"`  // 仅管理员审核通过后公开
	OperatingStatus string     `gorm:"size:20;not null;default:'active';index" json:"operating_status"`
	OfflinedAt      *time.Time `json:"offlined_at,omitempty"`
	OfflinedBy      *uint      `json:"-"`
	OfflineReason   string     `gorm:"size:500" json:"-"`
	IsOffline       bool       `gorm:"-" json:"is_offline"`
	CreatedBy       uint       `gorm:"index" json:"created_by"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`

	// 提交奖励经验状态：审核通过发放、下架/删除收回、恢复营业返还。
	ExpRewardedAt *time.Time `json:"-"`
	ExpRevokedAt  *time.Time `json:"-"`

	RatingCount int     `gorm:"-" json:"rating_count"`
	AverageStar float64 `gorm:"-" json:"average_star"`

	// 管理端待审核列表返回的提交人昵称（非数据库字段）
	CreatorName string `gorm:"-" json:"creator_name,omitempty"`
}

// NormalizeOperatingStatus 为历史数据库补齐状态，并计算只读 JSON 字段。
func (c *Canteen) NormalizeOperatingStatus() {
	if c.OperatingStatus == "" {
		c.OperatingStatus = CanteenOperatingActive
	}
	c.IsOffline = c.OperatingStatus == CanteenOperatingOffline
}

// EnsureCanteenOperatingStatusSchema 是幂等的历史数据补齐迁移。
func EnsureCanteenOperatingStatusSchema(db *gorm.DB) error {
	return db.Model(&Canteen{}).
		Where("operating_status IS NULL OR operating_status = ''").
		Update("operating_status", CanteenOperatingActive).Error
}

// CanteenRating 食堂评价
type CanteenRating struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	CanteenID      uint      `gorm:"index;not null" json:"canteen_id"`
	UserID         uint      `gorm:"index;not null" json:"user_id"`
	Star           int       `gorm:"not null" json:"star"`                      // 1-5星
	Comment        string    `gorm:"size:500" json:"comment"`                   // 评价文字
	Images         string    `gorm:"type:text" json:"images"`                   // 图片JSON数组
	Tags           string    `gorm:"type:text" json:"tags"`                     // 体验标签JSON数组
	HelpfulCount   int       `gorm:"not null;default:0" json:"helpful_count"`   // 有用票数
	UnhelpfulCount int       `gorm:"not null;default:0" json:"unhelpful_count"` // 无用票数
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
	Status         string    `gorm:"size:20;not null;default:'active';index" json:"status"`

	// V2 摘要字段。旧客户端继续读取 Star；新版使用 EffectiveScore 与五维摘要。
	EffectiveScore      float64 `gorm:"not null;default:0" json:"effective_score"`
	TasteScore          float64 `gorm:"not null;default:0" json:"taste_score"`
	ValueScore          float64 `gorm:"not null;default:0" json:"value_score"`
	QueueScore          float64 `gorm:"not null;default:0" json:"queue_score"`
	HygieneScore        float64 `gorm:"not null;default:0" json:"hygiene_score"`
	ServiceScore        float64 `gorm:"not null;default:0" json:"service_score"`
	ReviewEventCount    int     `gorm:"not null;default:0" json:"review_event_count"`
	LatestReviewEventID *uint   `gorm:"index" json:"latest_review_event_id,omitempty"`
	ScoreVersion        int     `gorm:"not null;default:1" json:"score_version"`

	// 关联数据（非数据库字段）
	User                 *User    `gorm:"foreignKey:UserID" json:"-"`
	UserName             string   `gorm:"-" json:"user_name"`
	UserStudentID        string   `gorm:"-" json:"user_student_id"`
	UserAvatar           string   `gorm:"-" json:"user_avatar"`
	MyVote               *string  `gorm:"-" json:"my_vote"`
	RecommendedDishNames []string `gorm:"-" json:"recommended_dishes,omitempty"`
	CreditScore          int      `gorm:"-" json:"credit_score,omitempty"`
	CreditWeight         float64  `gorm:"-" json:"credit_weight,omitempty"`
	HistoryCount         int      `gorm:"-" json:"history_count,omitempty"`
}

// CanteenRatingVote 食堂评价有用/无用投票
type CanteenRatingVote struct {
	ID        uint      `gorm:"primaryKey" json:"id"`
	RatingID  uint      `gorm:"not null;uniqueIndex:idx_canteen_rating_vote_user" json:"rating_id"`
	UserID    uint      `gorm:"not null;uniqueIndex:idx_canteen_rating_vote_user" json:"user_id"`
	VoteType  string    `gorm:"type:varchar(10);not null" json:"vote_type"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
