package models

import "time"

const (
	TopicStatusActive = "active"
	TopicStatusHidden = "hidden"
	TopicStatusMerged = "merged"
)

// Topic 是跨版块复用的自由话题实体。最终名称由服务端标准化后保存。
type Topic struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	Name           string    `gorm:"size:80;not null" json:"name"`
	NormalizedName string    `gorm:"size:80;not null;uniqueIndex" json:"-"`
	Status         string    `gorm:"size:20;not null;default:'active';index" json:"status"`
	UsageCount     int       `gorm:"not null;default:0;index" json:"usage_count"`
	MergedIntoID   *uint     `gorm:"index" json:"merged_into_id,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (Topic) TableName() string { return "topics" }

// TopicBrief 是帖子和 Topic API 对客户端暴露的最小话题 DTO。
type TopicBrief struct {
	ID   uint   `json:"id"`
	Name string `json:"name"`
}

// PostTopic 是显式关联表，保留排序和未来迁移扩展空间。
type PostTopic struct {
	PostID    uint      `gorm:"primaryKey;not null;index" json:"post_id"`
	TopicID   uint      `gorm:"primaryKey;not null;index" json:"topic_id"`
	SortOrder int       `gorm:"not null;default:0" json:"sort_order"`
	CreatedAt time.Time `json:"created_at"`
	Post      Post      `gorm:"foreignKey:PostID;constraint:OnDelete:CASCADE" json:"-"`
	Topic     Topic     `gorm:"foreignKey:TopicID" json:"-"`
}

func (PostTopic) TableName() string { return "post_topics" }
