package models_test

import (
	"testing"
	"time"

	"github.com/glebarez/sqlite"
	"gorm.io/gorm"

	"shenliyuan/internal/models"
)

func TestConversationNormalizesParticipantsAndRejectsDuplicates(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.AutoMigrate(&models.Conversation{}); err != nil {
		t.Fatalf("migrate conversation: %v", err)
	}

	first := models.Conversation{User1ID: 9, User2ID: 3}
	if err := db.Create(&first).Error; err != nil {
		t.Fatalf("create first conversation: %v", err)
	}
	if first.User1ID != 3 || first.User2ID != 9 {
		t.Fatalf("participants not normalized: user1=%d user2=%d", first.User1ID, first.User2ID)
	}

	duplicate := models.Conversation{User1ID: 3, User2ID: 9}
	if err := db.Create(&duplicate).Error; err == nil {
		t.Fatal("expected duplicate participant pair to violate unique index")
	}
}

func TestEnsureConversationIndexesCreatesMissingIndexes(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE conversations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user1_id INTEGER NOT NULL,
			user2_id INTEGER NOT NULL,
			last_message_at DATETIME,
			created_at DATETIME
		)
	`).Error; err != nil {
		t.Fatalf("create legacy conversations: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			conversation_id INTEGER NOT NULL,
			sender_id INTEGER NOT NULL,
			content TEXT,
			file_id INTEGER,
			created_at DATETIME,
			read_at DATETIME
		)
	`).Error; err != nil {
		t.Fatalf("create legacy messages: %v", err)
	}

	if err := models.EnsureConversationIndexes(db); err != nil {
		t.Fatalf("ensure indexes: %v", err)
	}

	expected := []struct {
		model interface{}
		name  string
	}{
		{&models.Conversation{}, "idx_conversation_users"},
		{&models.Conversation{}, "idx_conversations_user1_last_message"},
		{&models.Conversation{}, "idx_conversations_user2_last_message"},
		{&models.Message{}, "idx_messages_conversation_id_id"},
		{&models.Message{}, "idx_messages_conversation_read_sender"},
	}
	for _, index := range expected {
		if !db.Migrator().HasIndex(index.model, index.name) {
			t.Fatalf("missing index %s", index.name)
		}
	}
}

func TestNormalizeConversationPairsMergesLegacyDuplicates(t *testing.T) {
	db, err := gorm.Open(sqlite.Open(":memory:"), &gorm.Config{})
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE conversations (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user1_id INTEGER NOT NULL,
			user2_id INTEGER NOT NULL,
			last_message_at DATETIME,
			created_at DATETIME
		)
	`).Error; err != nil {
		t.Fatalf("create legacy conversations: %v", err)
	}
	if err := db.Exec(`
		CREATE TABLE messages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			conversation_id INTEGER NOT NULL,
			sender_id INTEGER NOT NULL,
			content TEXT,
			file_id INTEGER,
			created_at DATETIME,
			read_at DATETIME
		)
	`).Error; err != nil {
		t.Fatalf("create legacy messages: %v", err)
	}

	firstTime := time.Date(2026, 6, 14, 10, 0, 0, 0, time.UTC)
	lastTime := firstTime.Add(time.Minute)
	if err := db.Exec(
		"INSERT INTO conversations (id, user1_id, user2_id, created_at) VALUES (1, 9, 3, ?), (2, 3, 9, ?)",
		firstTime, firstTime,
	).Error; err != nil {
		t.Fatalf("insert conversations: %v", err)
	}
	if err := db.Exec(
		"INSERT INTO messages (conversation_id, sender_id, content, created_at) VALUES (1, 9, 'first', ?), (2, 3, 'last', ?)",
		firstTime, lastTime,
	).Error; err != nil {
		t.Fatalf("insert messages: %v", err)
	}

	if err := models.NormalizeConversationPairs(db); err != nil {
		t.Fatalf("normalize conversations: %v", err)
	}

	var conversations []models.Conversation
	if err := db.Find(&conversations).Error; err != nil {
		t.Fatalf("load conversations: %v", err)
	}
	if len(conversations) != 1 {
		t.Fatalf("conversation count=%d want=1", len(conversations))
	}
	conversation := conversations[0]
	if conversation.User1ID != 3 || conversation.User2ID != 9 {
		t.Fatalf("unexpected normalized pair: %d/%d", conversation.User1ID, conversation.User2ID)
	}
	if !conversation.LastMessageAt.Equal(lastTime) {
		t.Fatalf("last_message_at=%v want=%v", conversation.LastMessageAt, lastTime)
	}

	var messageCount int64
	db.Model(&models.Message{}).
		Where("conversation_id = ?", conversation.ID).
		Count(&messageCount)
	if messageCount != 2 {
		t.Fatalf("merged message count=%d want=2", messageCount)
	}
}
