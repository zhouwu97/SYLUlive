package models

import (
	"time"
)

// Conversation 私信会话
type Conversation struct {
	ID           uint      `gorm:"primaryKey" json:"id"`
	User1ID      uint      `gorm:"not null;index" json:"user1_id"`
	User2ID      uint      `gorm:"not null;index" json:"user2_id"`
	LastMessageAt time.Time `json:"last_message_at"`
	CreatedAt    time.Time `json:"created_at"`
	User1        User      `gorm:"foreignKey:User1ID" json:"user1"`
	User2        User      `gorm:"foreignKey:User2ID" json:"user2"`
}

// Message 私信消息
type Message struct {
	ID             uint       `gorm:"primaryKey" json:"id"`
	ConversationID  uint       `gorm:"not null;index" json:"conversation_id"`
	SenderID       uint       `gorm:"not null" json:"sender_id"`
	Content        string     `gorm:"type:text" json:"content"`
	FileID         *uint      `json:"file_id"` // 可选图片
	CreatedAt      time.Time  `json:"created_at"`
	ReadAt         *time.Time `json:"read_at"`
	Sender         User       `gorm:"foreignKey:SenderID" json:"sender"`
	File           *File      `gorm:"foreignKey:FileID" json:"file"`
}