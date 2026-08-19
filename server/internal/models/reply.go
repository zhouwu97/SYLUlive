package models

import (
	"encoding/json"
	"time"
)

// ReplyStatus 回复状态
type ReplyStatus string

const (
	ReplyStatusNormal  ReplyStatus = "normal"
	ReplyStatusDeleted ReplyStatus = "deleted"
)

// Reply 回复模型（支持一层嵌套）
type Reply struct {
	ID            uint        `gorm:"primaryKey" json:"id"`
	PostID        uint        `gorm:"not null;index:idx_replies_post_status_created,priority:1" json:"post_id"`
	ParentReplyID *uint       `gorm:"index" json:"parent_reply_id"` // 空表示顶级回复
	// ReplyToUserID 精确回复对象（被 @ 的用户）：楼中楼里点击某条子回复时，
	// 通知必须发给该用户，而不是根评论作者。
	ReplyToUserID *uint `gorm:"index" json:"reply_to_user_id,omitempty"`
	// ReplyToReplyID 精确回复对象（被回复的那条回复 ID）；必须与 ParentReplyID 同线程。
	ReplyToReplyID *uint `gorm:"index" json:"reply_to_reply_id,omitempty"`
	AuthorID       uint  `gorm:"not null" json:"author_id"`
	Content        string `gorm:"type:text" json:"content"`
	StickerID      *string `gorm:"size:64;index" json:"sticker_id,omitempty"`
	Status         ReplyStatus `gorm:"default:normal;index:idx_replies_post_status_created,priority:2" json:"status"`
	LikeCount      int         `gorm:"default:0" json:"like_count"`
	IsLiked        bool        `gorm:"-" json:"is_liked"`
	// ChildReplyCount 仅根评论返回：真实子回复总数（列表可能只携带前 N 条，其余懒加载）。
	ChildReplyCount int `gorm:"-" json:"child_reply_count,omitempty"`
	// 统一经验返回字段
	ExpEarned int `gorm:"-" json:"exp_earned,omitempty"`
	// ExpAwards 评论成功后本次下发的经验奖励（post 接口的子集，统一用同结构）。
	ExpAwards []ExpAward   `gorm:"-" json:"exp_awards,omitempty"`
	Images    []ReplyImage `gorm:"foreignKey:ReplyID" json:"images"`
	Author    User         `gorm:"foreignKey:AuthorID" json:"author"`
	CreatedAt time.Time    `gorm:"index:idx_replies_post_status_created,priority:3" json:"created_at"`
	UpdatedAt time.Time    `json:"updated_at"`
}

// MarshalJSON 确保回复作者始终使用公开 DTO，而非数据库 User 模型。
func (r Reply) MarshalJSON() ([]byte, error) {
	type replyAlias Reply
	return json.Marshal(struct {
		replyAlias
		Author PublicUserResponse `json:"author"`
	}{
		replyAlias: replyAlias(r),
		Author:     PublicUser(r.Author),
	})
}

// ReplyImage 回复图片关联
type ReplyImage struct {
	ID        uint `gorm:"primaryKey" json:"id"`
	ReplyID   uint `gorm:"not null" json:"reply_id"`
	FileID    uint `gorm:"not null" json:"file_id"`
	SortOrder int  `gorm:"default:0" json:"sort_order"`
	File      File `gorm:"foreignKey:FileID" json:"file"`
}
