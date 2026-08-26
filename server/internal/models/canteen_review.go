package models

import (
	"time"

	"gorm.io/gorm"
)

// ReviewEventStatus 是一次到店评价的生命周期状态。
const (
	ReviewEventStatusActive  = "active"
	ReviewEventStatusHidden  = "hidden"
	ReviewEventStatusDeleted = "deleted"
)

// DishReviewRelation 记录一次到店评价与菜品的关系。
const DishReviewRelationAte = "ate"

// CanteenReviewEvent 保存每一次真实到店评价，不受用户-食堂摘要唯一约束影响。
type CanteenReviewEvent struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	CanteenID      uint      `gorm:"not null;index:idx_canteen_review_event_canteen_created" json:"canteen_id"`
	UserID         uint      `gorm:"not null;index:idx_canteen_review_event_user_created" json:"user_id"`
	TasteScore     int       `gorm:"not null" json:"taste_score"`
	ValueScore     int       `gorm:"not null" json:"value_score"`
	QueueScore     int       `gorm:"not null" json:"queue_score"`
	HygieneScore   int       `gorm:"not null" json:"hygiene_score"`
	ServiceScore   int       `gorm:"not null" json:"service_score"`
	OverallScore   float64   `gorm:"not null" json:"overall_score"`
	Comment        string    `gorm:"size:500" json:"comment"`
	Images         string    `gorm:"type:text" json:"images"`
	Tags           string    `gorm:"type:text" json:"tags"`
	Status         string    `gorm:"size:20;not null;default:'active';index" json:"status"`
	ScoreVersion   int       `gorm:"not null;default:2" json:"score_version"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
	HelpfulCount   int       `gorm:"not null;default:0" json:"helpful_count"`
	UnhelpfulCount int       `gorm:"not null;default:0" json:"unhelpful_count"`

	User                   *User                    `gorm:"foreignKey:UserID" json:"-"`
	UserName               string                   `gorm:"-" json:"user_name,omitempty"`
	UserAvatar             string                   `gorm:"-" json:"user_avatar,omitempty"`
	CreditScore            int                      `gorm:"-" json:"credit_score,omitempty"`
	CreditWeight           float64                  `gorm:"-" json:"credit_weight,omitempty"`
	HistoryCount           int                      `gorm:"-" json:"history_count,omitempty"`
	RecommendedDishNames   []string                 `gorm:"-" json:"recommended_dishes,omitempty"`
	RecommendedDishDetails []map[string]interface{} `gorm:"-" json:"recommended_dish_details,omitempty"`
	MyVote                 *string                  `gorm:"-" json:"my_vote,omitempty"`
	Source                 string                   `gorm:"-" json:"source,omitempty"`
	LegacyRatingID         *uint                    `gorm:"-" json:"legacy_rating_id,omitempty"`
	CanEdit                bool                     `gorm:"-" json:"can_edit,omitempty"`
	CanDelete              bool                     `gorm:"-" json:"can_delete,omitempty"`
}

// CanteenReviewEventVote 保留 V2 评价的有用/无用投票，并用数据库唯一约束保证一人一票。
type CanteenReviewEventVote struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	ReviewEventID uint      `gorm:"not null;uniqueIndex:uq_review_event_vote_user" json:"review_event_id"`
	UserID        uint      `gorm:"not null;uniqueIndex:uq_review_event_vote_user" json:"user_id"`
	VoteType      string    `gorm:"size:10;not null" json:"vote_type"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// CanteenReviewEventDish 关联一次到店评价中实际吃到的菜品。
type CanteenReviewEventDish struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	ReviewEventID uint      `gorm:"not null;uniqueIndex:uq_review_event_dish_relation" json:"review_event_id"`
	DishID        uint      `gorm:"not null;uniqueIndex:uq_review_event_dish_relation;index" json:"dish_id"`
	Relation      string    `gorm:"size:20;not null;default:'ate'" json:"relation"`
	CreatedAt     time.Time `json:"created_at"`
}

// CanteenDishReviewEvent 菜品的独立评分事件，只包含味道、性价比、分量。
type CanteenDishReviewEvent struct {
	ID                   uint      `gorm:"primaryKey" json:"id"`
	DishID               uint      `gorm:"not null;index:idx_dish_review_event_dish_created" json:"dish_id"`
	UserID               uint      `gorm:"not null;index:idx_dish_review_event_user_created" json:"user_id"`
	TasteScore           int       `gorm:"not null" json:"taste_score"`
	ValueScore           int       `gorm:"not null" json:"value_score"`
	PortionScore         int       `gorm:"not null" json:"portion_score"`
	OverallScore         float64   `gorm:"not null" json:"overall_score"`
	Comment              string    `gorm:"size:500" json:"comment"`
	Status               string    `gorm:"size:20;not null;default:'active';index" json:"status"`
	ScoreVersion         int       `gorm:"not null;default:1" json:"score_version"`
	CanteenReviewEventID *uint     `gorm:"index" json:"canteen_review_event_id,omitempty"`
	CreatedAt            time.Time `json:"created_at"`
	UpdatedAt            time.Time `json:"updated_at"`

	User         *User   `gorm:"foreignKey:UserID" json:"-"`
	UserName     string  `gorm:"-" json:"user_name,omitempty"`
	UserAvatar   string  `gorm:"-" json:"user_avatar,omitempty"`
	CreditScore  int     `gorm:"-" json:"credit_score,omitempty"`
	CreditWeight float64 `gorm:"-" json:"credit_weight,omitempty"`
}

// CanteenDishRatingSummary 保留每个用户对每道菜的一个有效摘要。
type CanteenDishRatingSummary struct {
	ID                  uint      `gorm:"primaryKey" json:"id"`
	DishID              uint      `gorm:"not null;uniqueIndex:uq_dish_rating_summary_user" json:"dish_id"`
	UserID              uint      `gorm:"not null;uniqueIndex:uq_dish_rating_summary_user" json:"user_id"`
	EffectiveScore      float64   `gorm:"not null;default:0" json:"effective_score"`
	TasteScore          float64   `gorm:"not null;default:0" json:"taste_score"`
	ValueScore          float64   `gorm:"not null;default:0" json:"value_score"`
	PortionScore        float64   `gorm:"not null;default:0" json:"portion_score"`
	ReviewEventCount    int       `gorm:"not null;default:0" json:"review_event_count"`
	LatestReviewEventID *uint     `gorm:"index" json:"latest_review_event_id,omitempty"`
	CreatedAt           time.Time `json:"created_at"`
	UpdatedAt           time.Time `json:"updated_at"`
	User                *User     `gorm:"foreignKey:UserID" json:"-"`
}

// CanteenDishAlias 菜品别名。模糊匹配只用于提示，只有明确 alias 才能精确指向实体。
type CanteenDishAlias struct {
	ID              uint      `gorm:"primaryKey" json:"id"`
	CanteenID       uint      `gorm:"not null;uniqueIndex:uq_canteen_dish_alias" json:"canteen_id"`
	DishID          uint      `gorm:"not null;index" json:"dish_id"`
	Alias           string    `gorm:"size:100;not null" json:"alias"`
	NormalizedAlias string    `gorm:"size:100;not null;uniqueIndex:uq_canteen_dish_alias" json:"-"`
	CreatedBy       uint      `gorm:"not null;index" json:"created_by"`
	CreatedAt       time.Time `json:"created_at"`
}

// CanteenSanction 食堂内容治理处罚记录。
// ReportID 唯一约束保证管理员重复处理同一案件时不会重复扣诚信。
type CanteenSanction struct {
	ID         uint      `gorm:"primaryKey" json:"id"`
	ReportID   uint      `gorm:"not null;uniqueIndex" json:"report_id"`
	TargetType string    `gorm:"size:40;not null" json:"target_type"`
	TargetID   uint      `gorm:"not null;index" json:"target_id"`
	UserID     uint      `gorm:"not null;index" json:"user_id"`
	Points     int       `gorm:"not null" json:"points"`
	ReasonCode string    `gorm:"size:50;not null" json:"reason_code"`
	AdminID    uint      `gorm:"not null;index" json:"admin_id"`
	CreatedAt  time.Time `json:"created_at"`
}

// EnsureCanteenReviewSchema 建立 V2 评价相关表和索引。AutoMigrate 与显式索引均保持幂等。
func EnsureCanteenReviewSchema(db *gorm.DB) error {
	if err := db.AutoMigrate(
		&CanteenReviewEvent{},
		&CanteenReviewEventDish{},
		&CanteenReviewEventVote{},
		&CanteenDishReviewEvent{},
		&CanteenDishRatingSummary{},
		&CanteenDishAlias{},
		&CanteenSanction{},
	); err != nil {
		return err
	}
	return nil
}
