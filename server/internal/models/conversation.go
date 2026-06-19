package models

import (
	"time"

	"gorm.io/gorm"
)

// Conversation 私信会话
type Conversation struct {
	ID            uint      `gorm:"primaryKey" json:"id"`
	User1ID       uint      `gorm:"not null;index;uniqueIndex:idx_conversation_users;index:idx_conversations_user1_last_message,priority:1" json:"user1_id"`
	User2ID       uint      `gorm:"not null;index;uniqueIndex:idx_conversation_users;index:idx_conversations_user2_last_message,priority:1" json:"user2_id"`
	LastMessageAt time.Time `gorm:"index:idx_conversations_user1_last_message,priority:2;index:idx_conversations_user2_last_message,priority:2" json:"last_message_at"`
	CreatedAt     time.Time `json:"created_at"`
	User1         User      `gorm:"foreignKey:User1ID" json:"user1"`
	User2         User      `gorm:"foreignKey:User2ID" json:"user2"`
}

func (c *Conversation) BeforeSave(_ *gorm.DB) error {
	if c.User1ID > c.User2ID {
		c.User1ID, c.User2ID = c.User2ID, c.User1ID
	}
	if c.LastMessageAt.IsZero() {
		c.LastMessageAt = time.Now()
	}
	return nil
}

// Message 私信消息
type Message struct {
	ID             uint       `gorm:"primaryKey;index:idx_messages_conversation_id_id,priority:2" json:"id"`
	ConversationID uint       `gorm:"not null;index;index:idx_messages_conversation_id_id,priority:1;index:idx_messages_conversation_read_sender,priority:1" json:"conversation_id"`
	SenderID       uint       `gorm:"not null;index:idx_messages_conversation_read_sender,priority:3" json:"sender_id"`
	Content        string     `gorm:"type:text" json:"content"`
	FileID         *uint      `json:"file_id"` // 可选图片
	CreatedAt      time.Time  `json:"created_at"`
	ReadAt         *time.Time `gorm:"index:idx_messages_conversation_read_sender,priority:2" json:"read_at"`
	Sender         User       `gorm:"foreignKey:SenderID" json:"sender"`
	File           *File      `gorm:"foreignKey:FileID" json:"file"`
}

// NormalizeConversationPairs repairs legacy reversed/duplicate pairs before
// AutoMigrate creates the composite unique index.
func NormalizeConversationPairs(db *gorm.DB) error {
	if !db.Migrator().HasTable(&Conversation{}) {
		return nil
	}

	var conversations []Conversation
	if err := db.Order("id ASC").Find(&conversations).Error; err != nil {
		return err
	}

	return db.Transaction(func(tx *gorm.DB) error {
		keepers := make(map[[2]uint]uint, len(conversations))
		normalizedPairs := make(map[uint][2]uint, len(conversations))
		for _, conversation := range conversations {
			user1ID, user2ID := conversation.User1ID, conversation.User2ID
			if user1ID > user2ID {
				user1ID, user2ID = user2ID, user1ID
			}
			pair := [2]uint{user1ID, user2ID}
			normalizedPairs[conversation.ID] = pair

			if keeperID, exists := keepers[pair]; exists {
				if err := tx.Model(&Message{}).
					Where("conversation_id = ?", conversation.ID).
					Update("conversation_id", keeperID).Error; err != nil {
					return err
				}
				if err := tx.Delete(&Conversation{}, conversation.ID).Error; err != nil {
					return err
				}
				continue
			}

			keepers[pair] = conversation.ID
		}

		for pair, keeperID := range keepers {
			var keeper Conversation
			if err := tx.First(&keeper, keeperID).Error; err != nil {
				return err
			}
			normalizedPair := normalizedPairs[keeperID]
			if keeper.User1ID != normalizedPair[0] ||
				keeper.User2ID != normalizedPair[1] {
				if err := tx.Model(&Conversation{}).
					Where("id = ?", keeperID).
					Updates(map[string]interface{}{
						"user1_id": pair[0],
						"user2_id": pair[1],
					}).Error; err != nil {
					return err
				}
			}

			var lastMessage Message
			err := tx.Where("conversation_id = ?", keeperID).
				Order("id DESC").First(&lastMessage).Error
			if err == nil {
				if err := tx.Model(&Conversation{}).
					Where("id = ?", keeperID).
					Update("last_message_at", lastMessage.CreatedAt).Error; err != nil {
					return err
				}
			} else if err != gorm.ErrRecordNotFound {
				return err
			}
		}
		return nil
	})
}
